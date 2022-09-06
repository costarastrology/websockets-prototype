{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-| Inter-Server Communication Bus.

Use redis pub/sub to send messages between multiple API servers.
-}
module ISCB where

import           Control.Concurrent             ( threadDelay )
import           Control.Concurrent.Async.Lifted.Safe
                                                ( concurrently )
import           Control.Exception              ( Exception(displayException)
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


-- | One distinct grouping of messages we can send & receive.
data ISCBPing1Message = SendPing1
    deriving (Show, Read, Eq, Ord, Generic, ToJSON, FromJSON)

-- | A separate group of messages. Groups may be helpful for separating out
-- the usecases of different inter-server communications.
data ISCBPing2Message = SendPing2
    deriving (Show, Read, Eq, Ord, Generic, ToJSON, FromJSON)

-- | All channels we can send & receive from.
data ISCBChannel
    = Ping1Channel
    | Ping2Channel
    deriving (Show, Read, Eq, Ord)

-- | Encoding of channel. Could just derive a ToJSON instead...
channelName :: ISCBChannel -> BS.ByteString
channelName = \case
    Ping1Channel -> "ping1"
    Ping2Channel -> "ping2"

-- | Defines a mapping from a discrete message type to it's target PubSub
-- channel.
class MessageToChannel a where
    toChannel :: ISCBChannel

instance MessageToChannel ISCBPing1Message where
    toChannel = Ping1Channel
instance MessageToChannel ISCBPing2Message where
    toChannel = Ping2Channel

-- | Our handlers. You'd probably wanna define each somewhere that makes
-- more sense?
--
-- If we decide some standardized error message handling like below, we can
-- handle the `Left` case in 'makeMessageHandler'(with 'channelName
-- . toChannel' to make the error message) and only have to case match the
-- messages instead of a 'Either String msg'.
messageHandlers :: [(RedisChannel, MessageCallback)]
messageHandlers =
    [ mkPing1Handler $ \channel -> \case
        Left e ->
            putStrLn $ "Could not decode message from `ping1` channel: " <> e
        Right r -> case r of
            SendPing1 -> do
                formattedTime <- getFormattedTime
                putStrLn $ concat
                    [formattedTime, "[", BC.unpack channel, "] Pong 1"]
    , mkPing2Handler $ \channel -> \case
        Left e ->
            putStrLn $ "Could not decode message from `ping2` channel: " <> e
        Right r -> case r of
            SendPing2 -> do
                formattedTime <- getFormattedTime
                putStrLn $ concat
                    [formattedTime, "[", BC.unpack channel, "] Pong 2"]
    ]
  where
    getFormattedTime :: IO String
    getFormattedTime =
        formatTime defaultTimeLocale "[%H:%M:%S] " <$> getCurrentTime

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
withRedisSubs :: (Connection -> IO ()) -> IO ()
withRedisSubs nextTo = do
    conn             <- connect defaultConnectInfo
    pubSubController <- newPubSubController messageHandlers []
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
    :: (RedisChannel -> Either String ISCBPing1Message -> IO ())
    -> (RedisChannel, MessageCallback)
mkPing1Handler = makeMessageHandler

-- | Another helper we may find unnecessary.
mkPing2Handler
    :: (RedisChannel -> Either String ISCBPing2Message -> IO ())
    -> (RedisChannel, MessageCallback)
mkPing2Handler = makeMessageHandler

-- | Handle incoming messages from the redis channel for that specific
-- message type.
makeMessageHandler
    :: forall msg
     . (FromJSON msg, MessageToChannel msg)
    => (RedisChannel -> Either String msg -> IO ())
    -> (RedisChannel, MessageCallback)
makeMessageHandler handler =
    let channel = channelName $ toChannel @msg
    in  (channel, handler channel . eitherDecode' . LBS.fromStrict)
