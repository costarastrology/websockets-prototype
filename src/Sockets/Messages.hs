{-# LANGUAGE AllowAmbiguousTypes #-}
{-| Exposes functionality for sending messages to a single or all
connected clients, as well as building & executing handlers for incoming
message types.

You will want to define sendable & receivable message type for a single
communication channel. Use 'makeWebsocketHandler' to build a handler for
each receivable message and pass them to the
'Sockets.websocketsHandlerWithFallback' function used in your webserver.

-}
module Sockets.Messages
    ( WebsocketController
    , UserId
    , HasWSChannelName(..)
    -- * Sending
    , SendableWSMessage
    , broadcastMessage
    , sendMessage
    , sendMessageToLocalSubscribers
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

import           Sockets.Controller             ( SubscriptionIdentifier
                                                , UserId
                                                , WebsocketController
                                                , broadcastRawMessage
                                                , sendRawMessageToClient
                                                , sendRawMessageToSubscription
                                                )

import qualified Data.ByteString.Lazy          as LBS
import qualified Data.ByteString.Lazy.Char8    as LBC
import qualified Data.Text                     as T


-- GENERAL MESSAGE STRUCTURE

-- | Attach a channel name to a message. The channel name functions as
-- a switch point when decoding to determine what type we decode the
-- wmMessage to & the appropriate handler function to call.
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
-- This is used to dispatch incoming messages to the correct handler
-- functions. If you need to parameterize sending / receiving then look
-- into the "Sockets.Subscriptions" module.
class HasWSChannelName msg where
    wsChannelName :: T.Text

-- | Wrap the message in our WebSocketsData type so the channel is included
-- in the JSON encoding/decoding.
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
    :: SendableWSMessage msg
    => TVar WebsocketController
    -> UserId
    -> msg
    -> IO ()
sendMessage cm u = sendRawMessageToClient cm u . encode . toWebsocketsMessage

-- | Send a message to all clients sub'd to the subscription on the current
-- server.
sendMessageToLocalSubscribers
    :: SendableWSMessage msg
    => TVar WebsocketController
    -> SubscriptionIdentifier
    -> msg
    -> IO ()
sendMessageToLocalSubscribers wsCtl sub =
    sendRawMessageToSubscription wsCtl sub . encode . toWebsocketsMessage

-- | Send a message to all connected clients.
broadcastMessage
    :: SendableWSMessage msg => TVar WebsocketController -> msg -> IO ()
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

-- | A throwaway type we use to decode just the channel from a message.
--
-- With the channel name, we can pass the raw message to the appropriate
-- handler, which will take care of decoding the raw message into it's
-- respective message type.
newtype JustChannel = JustChannel { jcChannel :: T.Text } deriving (Show, Read, Eq, Ord)

instance FromJSON JustChannel where
    parseJSON = withObject "JustChannel" $ \o -> JustChannel <$> o .: "channel"
