{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-}
{-| Manage interserver WebSocket client subscriptions.

You'll want to define a new type representing a unique subscription, along
with types for sendable & receivable messages for that subscription. That
should allow you to define a 'WebsocketSubscription' instance for your
subscription type. You can then create a 'WebsocketHandler' for the
subscription using 'makeSubscriptionHandler' and send a message to all
subscribed clients using 'sendMessageToSubscription'.

See the "ChatRooms" module for an example implementation.

-}
module Sockets.Subscriptions
    ( WebsocketSubscription(..)
    , SubscriptionIdentifier(..)
    , sendMessageToSubscription
    , makeSubscriptionHandler
    ) where

import           Control.Concurrent.STM         ( TVar )
import           Control.Monad                  ( void
                                                , when
                                                )
import           Data.Aeson                     ( (.:)
                                                , (.=)
                                                , FromJSON(..)
                                                , ToJSON(..)
                                                , object
                                                , withObject
                                                )
import           Data.Kind                      ( Type )
import           Database.Redis                 ( MessageCallback
                                                , RedisChannel
                                                )

import           ISCB                           ( MessageToChannel(..)
                                                , makeMessageHandler
                                                , publishMessage
                                                )
import           Sockets.Controller             ( SubscriptionIdentifier(..)
                                                , UserId
                                                , WebsocketController
                                                , subscribeRaw
                                                , subscriptionIdToRedisChannel
                                                , unsubscribeRaw
                                                )
import           Sockets.Messages               ( ReceivableWSMessage
                                                , SendableWSMessage
                                                , WebsocketHandler
                                                , makeWebsocketHandler
                                                , sendMessageToLocalSubscribers
                                                )

import qualified Database.Redis                as R


-- | A type synonym family used to identify a communication channel that
-- websocket clients can subscribe to.
--
-- Each subscription is linked to websocket message types that can be sent
-- & received through it.
--
-- Subscription management and interserver message broadcasting is
-- automatically managed for you by using the 'makeSubscriptionHandler'
-- function instead of the 'makeWebsocketHandler' function.
--
-- Use 'sendMessageToSubscription' to send a message to all subscribed
-- clients across all servers.
class WebsocketSubscription a where
    -- | Arguments that are passed to various subscription management
    -- handler functions. This lets you access additional data in typeclass
    -- methods that is not explictly defined in this type family.
    type SubMgmtParams a :: Type
    -- | The type corresponding to messages that are sent to clients.
    type SubMsgForClient a :: Type
    -- | Pull the subscription's data from a message for a client.
    clientMsgSubscription :: SubMsgForClient a -> a
    -- | The type corresponding to messages that are received from clients.
    type SubMsgForServer a :: Type
    -- | Pull the subscription's data from a message from a client.
    serverMsgSubscription :: SubMsgForServer a -> a
    -- | Generate a unique identifier for a subscription. This is used to
    -- maintain the subscription mapping and as the name of the underlying
    -- redis communication channel. It should be unique across _all_
    -- WebsocketSubscription instances, so you probably want to add a very
    -- unique prefix.
    subscriptionIdentifier :: a -> SubscriptionIdentifier
    -- | Arbitrary code you can run after a client has been subscribed.
    onSubscribe :: SubMgmtParams a -> UserId -> a -> IO ()
    -- | Arbitrary code you can run after a client has been unsubscribed.
    onUnsubscribe :: SubMgmtParams a -> UserId -> a -> IO ()
    -- | Signals which message in the type is used to subscribe.
    isSubscribeMsg :: SubMsgForServer a -> Bool
    -- | Signals which message in the type is used to unsubscribe.
    isUnsubscribeMsg :: SubMsgForServer a -> Bool
    -- TODO: Hook for permissions check
    -- acceptMessage :: SubMgmtParams -> a -> SubMsgForServer a -> IO Bool
    -- TODO: Hook for internal state changes in response to interserver msg
    -- onRedisMessage :: SubMgmtParams -> a -> SubMsgForClient a -> IO ()
    -- TODO: Hook for some cleanup in an un-clean disconnect instead of an
    -- unsubscribe message.
    -- onDisconnect :: SubMgmtParams -> UserId -> a -> IO ()

-- | We automatically derive redis channels for sucbscriptions by re-using
-- the subscription id as the redis channel name.
instance WebsocketSubscription a => MessageToChannel (RedisPassthroughMessage a) where
    -- | Each unique subscription gets it's own redis channel.
    type MsgChannel (RedisPassthroughMessage a)
        = a
    toChannel (RedisPassthroughMessage s _) = s
    encodeChannel = subscriptionIdToRedisChannel . subscriptionIdentifier @a

data RedisPassthroughMessage a = RedisPassthroughMessage a (SubMsgForClient a)

instance (ToJSON (SubMsgForClient a), ToJSON a) => ToJSON (RedisPassthroughMessage a) where
    toJSON (RedisPassthroughMessage sub msg) =
        object ["sub" .= sub, "msg" .= msg]
instance (FromJSON (SubMsgForClient a), FromJSON a) => FromJSON  (RedisPassthroughMessage a) where
    parseJSON = withObject "RedisPassthroughMessage"
        $ \o -> RedisPassthroughMessage <$> o .: "sub" <*> o .: "msg"


-- | Send a message to all clients across all servers that are subscribed
-- to it's subscription.
sendMessageToSubscription
    :: forall sub
     . ( WebsocketSubscription sub
       , SendableWSMessage (SubMsgForClient sub)
       , ToJSON sub
       )
    => R.Connection
    -> SubMsgForClient sub
    -> IO ()
sendMessageToSubscription redisConn message =
    void . R.runRedis redisConn $ publishMessage $ RedisPassthroughMessage
        (clientMsgSubscription @sub message)
        message

-- | A wrapper around 'makeWebsocketHandler' that does all the bookkeeping
-- for subscription messages, such as managing both the websocket & redis
-- subscriptions and running callbacks in response to the appropriate
-- messages.
makeSubscriptionHandler
    :: forall sub
     . ( WebsocketSubscription sub
       , FromJSON sub
       , FromJSON (SubMsgForClient sub)
       , SendableWSMessage (SubMsgForClient sub)
       , ReceivableWSMessage (SubMsgForServer sub)
       , Show (SubMsgForServer sub)
       )
    => TVar WebsocketController
    -> SubMgmtParams sub
    -> (UserId -> SubMsgForServer sub -> IO ())
    -> WebsocketHandler
makeSubscriptionHandler wsCtl mgmtParams msgHandler =
    makeWebsocketHandler $ \uid msg -> do
        let subscription = serverMsgSubscription @sub msg
        when (isSubscribeMsg @sub msg) $ do
            -- TODO: permission check to see if allowed to subscribe?
            -- TODO: prevent onSubscribe if already subscribed?
            subscribe wsCtl uid subscription
            onSubscribe mgmtParams uid subscription
        when (isUnsubscribeMsg @sub msg) $ do
            -- TODO: prevent onUnsubscribe if not subscribed?
            unsubscribe wsCtl uid subscription
            onUnsubscribe mgmtParams uid subscription
        -- TODO: only call if subscribed?
        msgHandler uid msg

-- | Wrapper around the 'subscribeRaw' function, creating the redis handler
-- for passthrough messages & converting the sub to it's ID.
subscribe
    :: forall sub
     . ( FromJSON (SubMsgForClient sub)
       , FromJSON sub
       , WebsocketSubscription sub
       , SendableWSMessage (SubMsgForClient sub)
       )
    => TVar WebsocketController
    -> UserId
    -> sub
    -> IO ()
subscribe webSockCtl clientId subscription = do
    let subId        = subscriptionIdentifier @sub subscription
    let redisHandler = makeRedisHandler @sub webSockCtl subscription
    subscribeRaw webSockCtl clientId subId redisHandler

-- | Wrapper around the 'unsubscribeRaw' function, converting the sub to
-- it's ID.
unsubscribe
    :: forall sub
     . WebsocketSubscription sub
    => TVar WebsocketController
    -> UserId
    -> sub
    -> IO ()
unsubscribe webSockCtl clientId =
    unsubscribeRaw webSockCtl clientId . subscriptionIdentifier

-- | Listen for the passthrough messages & send them to the locally
-- subscribed clients.
makeRedisHandler
    :: forall sub
     . ( FromJSON (SubMsgForClient sub)
       , FromJSON sub
       , WebsocketSubscription sub
       , SendableWSMessage (SubMsgForClient sub)
       )
    => TVar WebsocketController
    -> sub
    -> (RedisChannel, MessageCallback)
makeRedisHandler webSockCtl subscription =
    makeMessageHandler subscription
        $ \_ (RedisPassthroughMessage (_ :: sub) msg) ->
              sendMessageToLocalSubscribers
                  webSockCtl
                  (subscriptionIdentifier @sub subscription)
                  msg
