{-# LANGUAGE AllowAmbiguousTypes #-}
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
import           Data.Kind                      ( Type )
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

import qualified Data.ByteString               as BS
import qualified Data.ByteString.Char8         as BC
import qualified Data.ByteString.Lazy          as LBS


-- MESSAGES

-- | Publish a message, routing it to the channel prescribed to it in it's
-- 'MessageToChannel' instance.
publishMessage
    :: forall a
     . (MessageToChannel a, ToJSON a)
    => a
    -> Redis (Either Reply Integer)
publishMessage msg =
    publish (encodeChannel @a $ toChannel msg) (LBS.toStrict $ encode msg)


-- CHANNELS

-- | Defines a mapping from a discrete message type to it's Redis PubSub
-- channel type.
class MessageToChannel msg where
    -- | Map the message to a discrete channel type.
    type MsgChannel msg :: Type
    -- | Determine the target channel for a given message.
    toChannel :: msg -> MsgChannel msg
    -- | Render the message type into a 'Database.Redis.RedisChannel'
    encodeChannel :: MsgChannel msg -> BS.ByteString


-- HANDLERS

-- | Connect to Redis & then fork a forever-running, parallel thread to
-- subscribe to the desired redis channels which is run alongside the
-- passed action.
withRedisSubs
    :: [(RedisChannel, MessageCallback)] -> (Connection -> IO ()) -> IO ()
withRedisSubs initialHandlers nextTo = do
    conn             <- connect defaultConnectInfo
    pubSubController <- newPubSubController initialHandlers []
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

-- | Handle incoming messages from the redis channel for that specific
-- message type.
makeMessageHandler
    :: forall msg
     . (FromJSON msg, MessageToChannel msg)
    => MsgChannel msg
    -> (RedisChannel -> msg -> IO ())
    -> (RedisChannel, MessageCallback)
makeMessageHandler channel handler =
    let channelName = encodeChannel @msg channel
    in  ( channelName
        , either
                (\e ->
                    putStrLn
                        $  "Could not decode message from `"
                        <> BC.unpack channelName
                        <> "` channel: "
                        <> e
                )
                (handler channelName)
            . eitherDecode'
            . LBS.fromStrict
        )
