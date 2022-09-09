{-| Implements a basic chat across multiple backend servers with websockets
for client<->server communication & redis pubsub for server<->server
communication.

-}
module Chat where

import           Control.Concurrent.STM         ( TVar )
import           Control.Monad                  ( void )
import           Data.Aeson                     ( FromJSON(..)
                                                , Options(..)
                                                , SumEncoding(..)
                                                , ToJSON(..)
                                                , defaultOptions
                                                , genericParseJSON
                                                , genericToJSON
                                                )
import           Data.Time                      ( UTCTime
                                                , getCurrentTime
                                                )
import           GHC.Generics                   ( Generic )

import           ISCB                           ( ISCBChannel(..)
                                                , MessageToChannel(..)
                                                , makeMessageHandler
                                                , publishMessage
                                                )
import           Sockets.Messages               ( ConnectionMap
                                                , HasWSChannelName(..)
                                                , ReceivableWSMessage
                                                , SendableWSMessage
                                                , UserId
                                                , broadcastMessage
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
    parseJSON = genericParseJSON jsonOptions


-- | WebSocket messages we can _send_ to clients.
data ChatWSMsgForClient = NewMessageReceived NewMessageData
    deriving (Show, Read, Eq, Ord, Generic)

instance SendableWSMessage ChatWSMsgForClient

instance ToJSON ChatWSMsgForClient where
    toJSON = genericToJSON jsonOptions

-- | This instance is needed for server<->server forwarding.
instance FromJSON ChatWSMsgForClient where
    parseJSON = genericParseJSON jsonOptions

-- | Data forthe 'NewMessageReceived' value.
data NewMessageData = NewMessageData
    { postedAt :: UTCTime
    , content  :: T.Text
    }
    deriving (Show, Read, Eq, Ord, Generic)

instance ToJSON NewMessageData where
    toJSON = genericToJSON dataJsonOptions
instance FromJSON NewMessageData where
    parseJSON = genericParseJSON dataJsonOptions


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
    toJSON = genericToJSON jsonOptions

instance FromJSON ChatInterServerMessage where
    parseJSON = genericParseJSON jsonOptions

instance MessageToChannel ChatInterServerMessage where
    toChannel = ChatWSRelay


-- HANDLERS

-- | Handler for incoming redis messages.
chatInterServerMessageHandler
    :: TVar ConnectionMap -> (R.RedisChannel, R.MessageCallback)
chatInterServerMessageHandler connMap = makeMessageHandler $ \_ -> \case
    BroadcastChatMessage subMsg -> broadcastMessage connMap subMsg

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



-- | Some reasonable JSON encoding/decoding options for our top-level
-- websocket & redis message types.
jsonOptions :: Options
jsonOptions = defaultOptions
    { allNullaryToStringTag = False
    , unwrapUnaryRecords    = False
    , tagSingleConstructors = True
    , sumEncoding           = TaggedObject { tagFieldName      = "type"
                                           , contentsFieldName = "contents"
                                           }
    }

-- | JSON encoding/decoding options for the XyzData types nested in
-- a top-level message type.
dataJsonOptions :: Options
dataJsonOptions = jsonOptions { tagSingleConstructors = False }
