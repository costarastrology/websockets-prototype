{-# LANGUAGE AllowAmbiguousTypes #-}
{-| Exposes functionality for sending messages to a single or all
connected clients, as well as building & executing handlers for incoming
message types.

TODO: Support dynamic, parameterized channels!

We need to match the structure of hedis pub/sub where we specify an initial
list of (channel, handlers) pairs, along with functions that can add or
remove a (channel, handler) pair. Which means we can't derive the channel
based on the message type. Clients should be able to send us generic
subscribe/unsubscribe messages that list them as listeners of a given channel.

-}
module Sockets.Messages
    ( ConnectionMap
    , UserId
    , HasWSChannelName(..)
    -- * Sending
    , SendableWSMessage
    , broadcastMessage
    , sendMessage
    -- * Receiving
    , ReceivableWSMessage
    , WebsocketHandler
    , makeWebsocketHandler
    , handleIncomingWebsocketMessages
    ) where


import           Control.Concurrent.STM         ( TVar )
import           Data.Aeson                     ( (.:)
                                                , (.=)
                                                , FromJSON(..)
                                                , ToJSON(..)
                                                , eitherDecode
                                                , encode
                                                , object
                                                , withObject
                                                )

import           Sockets.Connections            ( ConnectionMap
                                                , UserId
                                                , broadcastRawMessage
                                                , sendRawMessageToClient
                                                )

import qualified Data.ByteString.Lazy          as LBS
import qualified Data.ByteString.Lazy.Char8    as LBC
import qualified Data.Text                     as T


-- GENERAL MESSAGE STRUCTURE

data WebsocketMessage a = WebsocketMessage
    { wmChannel :: T.Text
    , wmMessage :: a
    }
    deriving (Show, Read, Eq, Ord)

instance FromJSON a => FromJSON (WebsocketMessage a) where
    parseJSON = withObject "WebsocketMessage"
        $ \o -> WebsocketMessage <$> o .: "channel" <*> o .: "message"

instance ToJSON a => ToJSON (WebsocketMessage a) where
    toJSON msg =
        object ["channel" .= wmChannel msg, "message" .= wmMessage msg]


-- | Specify a static channel name for a given websocket message.
--
-- TODO: this is intractable if we want routing of messages beyond a single
-- top-level handler. The channel name needs additional context during
-- generation and cannot be a fixed string.
--
-- E.g., we may want a @story-9001@ channel that clients can subscribe to,
-- where they receive updates only for the story with an ID of 9001.
class HasWSChannelName msg where
    wsChannelName :: T.Text

toWebsocketsMessage
    :: forall a . HasWSChannelName a => a -> WebsocketMessage a
toWebsocketsMessage msg =
    WebsocketMessage { wmChannel = wsChannelName @a, wmMessage = msg }


-- SENDING

-- | Blank class that functions as a simple opt-in to making a type
-- sendable via websockets.
class (HasWSChannelName msg, ToJSON msg) => SendableWSMessage msg

-- | Send a message to the client with the given ID.
sendMessage
    :: SendableWSMessage msg => TVar ConnectionMap -> UserId -> msg -> IO ()
sendMessage cm u = sendRawMessageToClient cm u . encode . toWebsocketsMessage

-- | Send a message to all connected clients.
broadcastMessage :: SendableWSMessage msg => TVar ConnectionMap -> msg -> IO ()
broadcastMessage cm msg =
    broadcastRawMessage cm . encode $ toWebsocketsMessage msg


-- RECEIVING


-- | Blank class that functions as a simple opt-in to making a type
-- receivable via websockets.
class (HasWSChannelName msg, FromJSON msg) => ReceivableWSMessage msg

-- | Opaque type representing a handler for a single channel of websocket
-- messages.
data WebsocketHandler = WebsocketHandler
    { whChannel :: T.Text
    , whHandler :: UserId -> LBS.ByteString -> IO ()
    }

-- | Build a new 'WebsocketHandler' given a handler function for
-- a 'ReceivableWSMessage'.
makeWebsocketHandler
    :: forall msg
     . (ReceivableWSMessage msg, Show msg)
    => (UserId -> msg -> IO ())
    -> WebsocketHandler
makeWebsocketHandler handler = WebsocketHandler
    { whChannel = wsChannelName @msg
    , whHandler = \uid rawMsg -> case eitherDecode rawMsg of
                      Left err ->
                          LBC.putStrLn
                              $  "[WebSocket] ["
                              <> LBC.pack (show uid)
                              <> "] Could not parse message: "
                              <> rawMsg
                              <> " ; Got: "
                              <> LBC.pack err
                      Right msg -> do
                          putStrLn
                              $  "[WebSocket] ["
                              <> show uid
                              <> "] "
                              <> show msg
                          handler uid $ wmMessage msg
    }

-- | Process an incoming websocket message by decoding the channel
-- & dispatching it to the correct 'WebsocketHandler'.
handleIncomingWebsocketMessages
    :: UserId -> [WebsocketHandler] -> LBS.ByteString -> IO ()
handleIncomingWebsocketMessages uid allHandlers rawMsg =
    case jcChannel <$> eitherDecode rawMsg of
        Left err ->
            LBC.putStrLn
                $  "[WebSocket] ["
                <> LBC.pack (show uid)
                <> "] Could not parse channel: "
                <> rawMsg
                <> " ; Got: "
                <> LBC.pack err
        Right channelName -> do
            let matchingChannels =
                    filter ((== channelName) . whChannel) allHandlers
            mapM_ (($ rawMsg) . ($ uid) . whHandler) matchingChannels

newtype JustChannel = JustChannel { jcChannel :: T.Text } deriving (Show, Read, Eq, Ord)

instance FromJSON JustChannel where
    parseJSON = withObject "JustChannel" $ \o -> JustChannel <$> o .: "channel"
