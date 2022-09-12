{-| Implements a pinging action from an endpoint to all websocket
clients.

-}
module Ping where

import           Control.Concurrent.STM         ( TVar )
import           Data.Aeson                     ( FromJSON(..)
                                                , ToJSON(..)
                                                , genericParseJSON
                                                , genericToJSON
                                                )
import           GHC.Generics                   ( Generic )

import           ISCB                           ( MessageToChannel(..)
                                                , makeMessageHandler
                                                )
import           Sockets.Messages               ( ConnectionMap
                                                , HasWSChannelName(..)
                                                , SendableWSMessage
                                                , broadcastMessage
                                                )
import           Utils                          ( getFormattedTime
                                                , msgJsonOptions
                                                )

import qualified Data.ByteString.Char8         as BC
import qualified Database.Redis                as R

{-# ANN module ("HLint: ignore Use newtype instead of data" :: String) #-}


-- WS MESSAGES

-- | Ping a client with a sepcific ping number.
data PingWSMsgForClient = Ping Int
    deriving (Show, Read, Eq, Ord, Generic)

instance SendableWSMessage PingWSMsgForClient

instance ToJSON PingWSMsgForClient where
    toJSON = genericToJSON msgJsonOptions

instance HasWSChannelName PingWSMsgForClient where
    wsChannelName = "ping"


-- REDIS MESSAGES

-- | Each ping is a separate value but we've collapsed the type.
data PingInterServerMessage
    = SendPing1
    | SendPing2
    deriving (Show, Read, Eq, Ord, Generic)

instance ToJSON PingInterServerMessage where
    toJSON = genericToJSON msgJsonOptions

instance FromJSON PingInterServerMessage where
    parseJSON = genericParseJSON msgJsonOptions

-- | Pings can go through multiple redis channels.
data PingRedisChannel = PingChannel Int

instance MessageToChannel PingInterServerMessage where
    type MsgChannel PingInterServerMessage = PingRedisChannel
    toChannel = \case
        SendPing1 -> PingChannel 1
        SendPing2 -> PingChannel 2
    encodeChannel = \case
        PingChannel num -> "ping" <> BC.pack (show num)


-- HANDLERS

-- | Broadcast the correct 'Ping' when receiving a redis message.
pingInterServerMessageHandlers
    :: TVar ConnectionMap -> [(R.RedisChannel, R.MessageCallback)]
pingInterServerMessageHandlers connMap =
    [ makeMessageHandler (PingChannel 1) $ \channel -> \case
        SendPing1 -> do
            formattedTime <- getFormattedTime
            putStrLn
                $ concat
                      [ "[Redis] "
                      , formattedTime
                      , "["
                      , BC.unpack channel
                      , "] Pong 1"
                      ]
            broadcastMessage connMap $ Ping 1
        _ -> return ()
    , makeMessageHandler (PingChannel 2) $ \channel -> \case
        SendPing2 -> do
            formattedTime <- getFormattedTime
            putStrLn
                $ concat
                      [ "[Redis] "
                      , formattedTime
                      , "["
                      , BC.unpack channel
                      , "] Pong 2"
                      ]
            broadcastMessage connMap $ Ping 2
        _ -> return ()
    ]
