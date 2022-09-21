{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-| A websockets connection controller along with low-level querying,
sending, & manipulation functions.

TODO: by consolidating this module w/ 'Sockets.Messages', we could remove the
"raw" message sending functions.

-}
module Sockets.Controller
    ( UserId
    , WebsocketController
    , initializeWebsocketsController
    -- * Registration
    , registerNewClient
    , unregisterClient
    -- * Querying
    , getConnectedClients
    , getSubscribers
    , getSubscriptions
    -- * Messaging
    , sendRawMessageToClient
    , sendRawMessageToSubscription
    , broadcastRawMessage
    -- * Subscription
    , SubscriptionIdentifier(..)
    , subscriptionIdToRedisChannel
    , subscribeRaw
    , unsubscribeRaw
    ) where

import           Control.Arrow                  ( (&&&) )
import           Control.Concurrent.STM         ( STM
                                                , TVar
                                                , atomically
                                                , modifyTVar
                                                , newTVarIO
                                                , readTVar
                                                , readTVarIO
                                                , stateTVar
                                                )
import           Control.Monad                  ( forM_
                                                , unless
                                                , void
                                                , when
                                                )
import           Data.Hashable                  ( Hashable )
import           Data.Maybe                     ( isNothing
                                                , mapMaybe
                                                )
import           Data.Text                      ( Text )
import           Data.UUID                      ( UUID )
import           Data.UUID.V4                   ( nextRandom )
import           Database.Redis                 ( MessageCallback
                                                , PubSubController
                                                , RedisChannel
                                                , addChannels
                                                , removeChannels
                                                )
import           Network.WebSockets             ( Connection
                                                , sendTextData
                                                )

import qualified Data.ByteString.Char8         as BC8
import qualified Data.ByteString.Lazy          as LBS
import qualified Data.HashMap.Strict           as HM
import qualified Data.Map.Strict               as M
import qualified Data.Set                      as S
import qualified Data.Text                     as T


-- | Placeholder type for our @user.id@ database column.
--
-- We use this to accept & identify _any_ websocket connection. In reality,
-- we should be inspecting the request headers, decoding the Auth Token
-- into a DB-backed 'UserId', & rejecting the connection when authorization
-- fails. We should see if putting the websockets route under a Servant
-- @AuthProtect@ will do all of the above work for us.
type UserId = UUID

-- | Subscription identifiers. Used to track who has subscribed to what, as
-- well as providing a Redis ChannelName for interserver messaging.
newtype SubscriptionIdentifier = SubscriptionIdentifier
    { fromSubscriptionIdentifier :: Text
    }
    deriving (Show, Read, Eq, Ord, Hashable)

-- | Convert a SubId to it's equivalent RedisChannel. This is currently
-- just a transformation between different string types, the actual
-- identifier is unmodified.
subscriptionIdToRedisChannel :: SubscriptionIdentifier -> RedisChannel
subscriptionIdToRedisChannel = BC8.pack . T.unpack . fromSubscriptionIdentifier


-- CONNECTION MANAGEMENT

-- | Internal WebSockets state for a single server instance.
data WebsocketController = WebsocketController
    { wscConnMap   :: M.Map UserId Connection
    -- ^ The Users/Connections that a server instance knows about.
    , wscSubMap    :: HM.HashMap SubscriptionIdentifier (S.Set UserId)
    -- ^ The active client subscriptions.
    , wscPubSubCtl :: PubSubController
    -- ^ The redis connection's pub/sub service.
    }

-- | Build a new controller with no connections or subscriptions.
initializeWebsocketsController
    :: PubSubController -> IO (TVar WebsocketController)
initializeWebsocketsController pubSubCtl = newTVarIO WebsocketController
    { wscConnMap   = M.empty
    , wscSubMap    = HM.empty
    , wscPubSubCtl = pubSubCtl
    }

-- | Add a new connection to the user mapping, assigning & returning a new
-- UserId.
registerNewClient :: TVar WebsocketController -> Connection -> IO UserId
registerNewClient contrTVar newConnection = do
    clientId <- nextRandom
    atomically . modifyTVar contrTVar $ \controller -> controller
        { wscConnMap = M.insert clientId newConnection $ wscConnMap controller
        }
    return clientId

-- | Remove a client's connection & unsubscribe them from everything.
unregisterClient :: TVar WebsocketController -> UserId -> IO ()
unregisterClient contrTVar clientId = do
    atomically . modifyTVar contrTVar $ \controller -> controller
        { wscConnMap = M.delete clientId $ wscConnMap controller
        }
    unsubscribeAll contrTVar clientId


-- QUERYING

-- | Retrieve all connected clients.
getConnectedClients :: TVar WebsocketController -> STM [UserId]
getConnectedClients = fmap (M.keys . wscConnMap) . readTVar

-- | Retrieve all clients in the given subscription.
getSubscribers
    :: TVar WebsocketController -> SubscriptionIdentifier -> STM [UserId]
getSubscribers contrTVar sub =
    maybe [] S.toList . HM.lookup sub . wscSubMap <$> readTVar contrTVar

-- | Retrieve all active subscriptions.
getSubscriptions :: TVar WebsocketController -> STM [SubscriptionIdentifier]
getSubscriptions = fmap (HM.keys . wscSubMap) . readTVar


-- MESSAGING

-- | Send a message to a locally connected client with the given ID.
sendRawMessageToClient
    :: TVar WebsocketController -> UserId -> LBS.ByteString -> IO ()
sendRawMessageToClient contrTVar clientId message = do
    mbClientConnection <-
        M.lookup clientId . wscConnMap <$> readTVarIO contrTVar
    forM_ mbClientConnection $ \c -> sendTextData c message

-- | Send a message to all sbuscribed clients that _this_ controller knows
-- about. Does not propogate to other servers!
sendRawMessageToSubscription
    :: TVar WebsocketController
    -> SubscriptionIdentifier
    -> LBS.ByteString
    -> IO ()
sendRawMessageToSubscription contrTVar subscription message = do
    subscriptionConnections <- atomically $ do
        controller <- readTVar contrTVar
        let
            subscribers =
                maybe [] S.toList . HM.lookup subscription $ wscSubMap
                    controller
        let connections =
                mapMaybe (`M.lookup` wscConnMap controller) subscribers
        return connections
    forM_ subscriptionConnections $ \c -> sendTextData c message

-- | Send a message to all locally connected clients.
broadcastRawMessage :: TVar WebsocketController -> LBS.ByteString -> IO ()
broadcastRawMessage contrTVar message = do
    allClients <- M.elems . wscConnMap <$> readTVarIO contrTVar
    forM_ allClients $ flip sendTextData message


-- SUBSCRIBING

-- | If we have a connection for the user, add them to a subscription.
--
-- If this is the first user for the subscription, install the redis
-- handler for the specific subscription.
--
-- Note: we could ditch the 'RedisChannel' argument here since we can
-- determine it from the 'SubscriptionIdentifier'.
subscribeRaw
    :: TVar WebsocketController
    -> UserId
    -> SubscriptionIdentifier
    -> (RedisChannel, MessageCallback)
    -> IO ()
subscribeRaw contrTVar clientId subscription redisHandler = do
    (needsRedisHandler, pubSubCtl) <- atomically $ do
        initialController <- readTVar contrTVar
        let needsRedisHandler =
                isNothing . HM.lookup subscription $ wscSubMap initialController
        let isConnected = M.member clientId $ wscConnMap initialController
        let isSubscribed =
                (isConnected &&)
                    . maybe False (S.member clientId)
                    . HM.lookup subscription
                    $ wscSubMap initialController
        unless (not isConnected || isSubscribed)
            $ modifyTVar contrTVar
            $ \controller -> controller
                  { wscSubMap =
                      HM.alter
                              (\case
                                  Just subscribers ->
                                      Just $ S.insert clientId subscribers
                                  Nothing -> Just $ S.fromList [clientId]
                              )
                              subscription
                          $ wscSubMap controller
                  }
        return
            (needsRedisHandler && isConnected, wscPubSubCtl initialController)
    when needsRedisHandler $ void $ addChannels pubSubCtl [redisHandler] []

-- | Unsubscribe the user from a subscription.
--
-- If this is the last user in the subscription, remove the channel's redis
-- handler.
unsubscribeRaw
    :: TVar WebsocketController -> UserId -> SubscriptionIdentifier -> IO ()
unsubscribeRaw contrTVar clientId subscription = do
    (needsRedis, pubSubCtl) <- atomically $ do
        modifyTVar contrTVar $ \controller -> controller
            { wscSubMap =
                HM.alter
                        (\case
                            Nothing -> Nothing
                            Just subscribers ->
                                removeSubscriber clientId subscribers
                        )
                        subscription
                    $ wscSubMap controller
            }
        controller <- readTVar contrTVar
        return $ (HM.member subscription . wscSubMap &&& wscPubSubCtl)
            controller
    unless needsRedis $ removeChannels
        pubSubCtl
        [subscriptionIdToRedisChannel subscription]
        []


-- | Unsubscribe the user from _all_ subscriptions.
--
-- Remove the redis handlers for any subscriptions where the user is the
-- last person subscribed.
--
-- TODO: this is only used in unregisterClient - we could keep this in STM,
-- return a list of now-empty channels & do the IO unregistration in
-- unregisterClient...
unsubscribeAll :: TVar WebsocketController -> UserId -> IO ()
unsubscribeAll contrTVar clientId = do
    (removedSubs, pubSubCtl) <-
        atomically . stateTVar contrTVar $ \controller ->
            let
                -- Remove the subscriber from any subs, deleting & accumulating
                -- any now empty subs.
                (removedSubs, newSubMap) =
                    HM.foldrWithKey
                            (\sub subscribers (removed, newMap) ->
                                case removeSubscriber clientId subscribers of
                                    Nothing -> (sub : removed, newMap)
                                    Just newSubscribers ->
                                        ( removed
                                        , HM.insert sub newSubscribers newMap
                                        )
                            )
                            ([], HM.empty)
                        $ wscSubMap controller
            in  ( (removedSubs, wscPubSubCtl controller)
                , controller { wscSubMap = newSubMap }
                )
    unless (null removedSubs) $ removeChannels
        pubSubCtl
        (map subscriptionIdToRedisChannel removedSubs)
        []

-- | Remove a subscriber from the subscriber set, returning nothing if no
-- subscribers remain.
removeSubscriber :: UserId -> S.Set UserId -> Maybe (S.Set UserId)
removeSubscriber clientId subscribers =
    let newSubs = S.delete clientId subscribers
    in  if S.null newSubs then Nothing else Just newSubs
