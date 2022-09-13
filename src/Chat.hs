{-| Implements a basic chat across multiple backend servers with websockets
for client<->server communication & redis pubsub for server<->server
communication.

-}
module Chat where

import           Control.Concurrent.STM         ( TVar )
import           Control.Monad                  ( void )
import           Data.Aeson                     ( FromJSON(..)
                                                , ToJSON(..)
                                                , genericParseJSON
                                                , genericToJSON
                                                )
import           Data.Time                      ( UTCTime
                                                , getCurrentTime
                                                )
import           GHC.Generics                   ( Generic )

import           ISCB                           ( MessageToChannel(..)
                                                , makeMessageHandler
                                                , publishMessage
                                                )
import           Sockets.Messages               ( HasWSChannelName(..)
                                                , ReceivableWSMessage
                                                , SendableWSMessage
                                                , UserId
                                                , WebsocketController
                                                , broadcastMessage
                                                )
import           Utils                          ( msgDataJsonOptions
                                                , msgJsonOptions
                                                )

import qualified Data.Text                     as T
import qualified Database.Redis                as R

{-# ANN module ("HLint: ignore Use newtype instead of data" :: String) #-}


-- WS MESSAGES

-- | WebSocket messages we can _receive_ from clients.
data ChatWSMsgForServer = SubmitMessage T.Text
    deriving (Show, Read, Eq, Ord, Generic)

instance ReceivableWSMessage ChatWSMsgForServer

instance FromJSON ChatWSMsgForServer where
    parseJSON = genericParseJSON msgJsonOptions


-- | WebSocket messages we can _send_ to clients.
data ChatWSMsgForClient = NewMessageReceived NewMessageData
    deriving (Show, Read, Eq, Ord, Generic)

instance SendableWSMessage ChatWSMsgForClient

instance ToJSON ChatWSMsgForClient where
    toJSON = genericToJSON msgJsonOptions

-- | This instance is needed for server<->server forwarding.
instance FromJSON ChatWSMsgForClient where
    parseJSON = genericParseJSON msgJsonOptions

-- | Data forthe 'NewMessageReceived' value.
data NewMessageData = NewMessageData
    { postedAt :: UTCTime
    , content  :: T.Text
    }
    deriving (Show, Read, Eq, Ord, Generic)

instance ToJSON NewMessageData where
    toJSON = genericToJSON msgDataJsonOptions
instance FromJSON NewMessageData where
    parseJSON = genericParseJSON msgDataJsonOptions


instance HasWSChannelName ChatWSMsgForServer where
    wsChannelName = "chat"
instance HasWSChannelName ChatWSMsgForClient where
    wsChannelName = "chat"


-- REDIS MESSAGES

-- | Redis messages for broadcasting WS client messages.
--
-- TODO: it'd be dope if we could auto-generate this type
-- & a "re-broadcast" helper function with template haskell:
-- @$(generateWebsocketsRedisMessage 'ChatWSMsgForClient)@
data ChatInterServerMessage = BroadcastChatMessage ChatWSMsgForClient
    deriving (Show, Read, Eq, Ord, Generic)

instance ToJSON ChatInterServerMessage where
    toJSON = genericToJSON msgJsonOptions

instance FromJSON ChatInterServerMessage where
    parseJSON = genericParseJSON msgJsonOptions

-- | Interserver chat communication occurs through a single Redis channel.
data ChatRedisChannel = ChatRedisChannel

instance MessageToChannel ChatInterServerMessage where
    type MsgChannel ChatInterServerMessage = ChatRedisChannel
    toChannel _ = ChatRedisChannel
    encodeChannel _ = "websockets-chat-relay"


-- HANDLERS

-- | Handler for incoming redis messages.
chatInterServerMessageHandler
    :: TVar WebsocketController -> (R.RedisChannel, R.MessageCallback)
chatInterServerMessageHandler wsController =
    makeMessageHandler ChatRedisChannel $ \_ -> \case
        BroadcastChatMessage subMsg -> broadcastMessage wsController subMsg

-- | Handler for incoming websocket messages.
chatClientMessageHandler
    :: R.Connection -> UserId -> ChatWSMsgForServer -> IO ()
chatClientMessageHandler redisConn _ = \case
    SubmitMessage msgText -> do
        receiveTime <- getCurrentTime
        void
            . R.runRedis redisConn
            . publishMessage
            . BroadcastChatMessage
            . NewMessageReceived
            $ NewMessageData receiveTime msgText
