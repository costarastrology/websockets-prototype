{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-| Inter-Server Communication Bus.

Use redis pub/sub to send messages between multiple API servers.
-}
module ISCB where

import           Control.Concurrent             ( threadDelay )
import           Control.Concurrent.Async.Lifted.Safe
                                                ( concurrently )
import           Control.Exception.Safe         ( Exception(displayException)
                                                , SomeException
                                                , catch
                                                )
import           Control.Monad                  ( forever
                                                , void
                                                )
import           Data.Aeson                     ( FromJSON(..)
                                                , ToJSON(..)
                                                , eitherDecode'
                                                , encode
                                                )
import           Data.Time                      ( defaultTimeLocale
                                                , formatTime
                                                , getCurrentTime
                                                )
import           Database.Redis                 ( Connection
                                                , MessageCallback
                                                , Redis
                                                , RedisChannel
                                                , Reply
                                                , connect
                                                , defaultConnectInfo
                                                , newPubSubController
                                                , pubSubForever
                                                , publish
                                                )
import           GHC.Generics                   ( Generic )

import qualified Data.ByteString               as BS
import qualified Data.ByteString.Char8         as BC
import qualified Data.ByteString.Lazy          as LBS


-- MESSAGES

-- | One distinct grouping of messages we can send & receive.
data ISCBPing1Message = SendPing1
    deriving (Show, Read, Eq, Ord, Generic, ToJSON, FromJSON)

-- | A dumb handler for 'ISCBPing1Message's.
ping1Handler :: RedisChannel -> ISCBPing1Message -> IO ()
ping1Handler channel = \case
    SendPing1 -> do
        formattedTime <- getFormattedTime
        putStrLn $ concat [formattedTime, "[", BC.unpack channel, "] Pong 1"]

-- | A separate group of messages. Groups may be helpful for separating out
-- the usecases of different inter-server communications.
data ISCBPing2Message = SendPing2
    deriving (Show, Read, Eq, Ord, Generic, ToJSON, FromJSON)

-- | A dumb handler for 'ISCBPing2Message's.
ping2Handler :: RedisChannel -> ISCBPing2Message -> IO ()
ping2Handler channel = \case
    SendPing2 -> do
        formattedTime <- getFormattedTime
        putStrLn $ concat [formattedTime, "[", BC.unpack channel, "] Pong 2"]

-- | Handle messages that come through a subscription. This is used as
-- initial subscription list when starting up the pubsub listener.
messageHandlers :: [(RedisChannel, MessageCallback)]
messageHandlers = [mkPing1Handler ping1Handler, mkPing2Handler ping2Handler]


-- CHANNELS

-- | All channels we can send & receive from.
data ISCBChannel
    = Ping1Channel
    | Ping2Channel
    | ChatWSRelay
    -- ^ TODO: It seems bad we have to define this here?
    -- Should we have 'MessageToChannel' be something like:
    -- @toChannel :: a -> ByteString@ or @toChannel :: ByteString@?
    deriving (Show, Read, Eq, Ord)

-- | Encoding of channel. Could just derive a ToJSON instead...
channelName :: ISCBChannel -> BS.ByteString
channelName = \case
    Ping1Channel -> "ping1"
    Ping2Channel -> "ping2"
    ChatWSRelay  -> "websockets-chat-relay"

-- | Defines a mapping from a discrete message type to it's target PubSub
-- channel.
class MessageToChannel a where
    toChannel :: ISCBChannel

instance MessageToChannel ISCBPing1Message where
    toChannel = Ping1Channel
instance MessageToChannel ISCBPing2Message where
    toChannel = Ping2Channel


-- INFRASTRUCTURE

-- | Publish a message, routing it to the channel prescribed to it in it's
-- 'MessageToChannel' instance.
publishMessage
    :: forall a
     . (MessageToChannel a, ToJSON a)
    => a
    -> Redis (Either Reply Integer)
publishMessage cmsg =
    publish (channelName $ toChannel @a) (LBS.toStrict $ encode cmsg)

-- | Connect to Redis & then fork a forever-running, parallel thread to
-- subscribe to the desired redis channels which is run alongside the
-- passed action.
withRedisSubs
    :: [(RedisChannel, MessageCallback)] -> (Connection -> IO ()) -> IO ()
withRedisSubs extraHandlers nextTo = do
    conn             <- connect defaultConnectInfo
    pubSubController <- newPubSubController
        (extraHandlers <> messageHandlers)
        []
    void $ concurrently
        (       forever
        $       pubSubForever conn
                              pubSubController
                              (putStrLn "Redis Channel Subscription Complete")
        `catch` (\(e :: SomeException) ->
                    putStrLn
                            (  "Redis listeners died with: "
                            <> displayException e
                            )
                        >> threadDelay (1000 * 50)
                )
        )
        (nextTo conn)

-- | Not really necessary, but gives us a little documentation?
mkPing1Handler
    :: (RedisChannel -> ISCBPing1Message -> IO ())
    -> (RedisChannel, MessageCallback)
mkPing1Handler = makeMessageHandler

-- | Another helper we may find unnecessary.
mkPing2Handler
    :: (RedisChannel -> ISCBPing2Message -> IO ())
    -> (RedisChannel, MessageCallback)
mkPing2Handler = makeMessageHandler

-- | Handle incoming messages from the redis channel for that specific
-- message type.
makeMessageHandler
    :: forall msg
     . (FromJSON msg, MessageToChannel msg)
    => (RedisChannel -> msg -> IO ())
    -> (RedisChannel, MessageCallback)
makeMessageHandler handler =
    let channel = channelName $ toChannel @msg
    in  ( channel
        , either
                (\e ->
                    putStrLn
                        $  "Could not decode message from `"
                        <> BC.unpack channel
                        <> "` channel: "
                        <> e
                )
                (handler channel)
            . eitherDecode'
            . LBS.fromStrict
        )


-- MISC

-- | Render the current time in a nice format for logging.
getFormattedTime :: IO String
getFormattedTime =
    formatTime defaultTimeLocale "[%H:%M:%S] " <$> getCurrentTime
