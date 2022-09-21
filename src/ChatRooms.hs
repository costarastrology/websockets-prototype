{-# LANGUAGE DuplicateRecordFields #-}
{-| A more complex Chat implementation compared to "Chat". This module
demonstrates how users can subscribe to a subset of messages(a chatroom)
and how we send messages for that chatroom to only subscribed users.

-}
module ChatRooms
    ( chatRoomClientMessageHandler
    ) where

import           Control.Concurrent.STM         ( TVar )
import           Data.Aeson                     ( FromJSON(..)
                                                , ToJSON(..)
                                                , genericParseJSON
                                                , genericToJSON
                                                )
import           Data.Text                      ( Text )
import           GHC.Generics                   ( Generic )

import           Sockets.Messages               ( HasWSChannelName(..)
                                                , ReceivableWSMessage
                                                , SendableWSMessage
                                                , UserId
                                                , WebsocketController
                                                , WebsocketHandler
                                                , sendMessage
                                                )
import           Sockets.Subscriptions          ( SubscriptionIdentifier(..)
                                                , WebsocketSubscription(..)
                                                , makeSubscriptionHandler
                                                , sendMessageToSubscription
                                                )
import           Utils                          ( msgDataJsonOptions
                                                , msgJsonOptions
                                                )

import qualified Database.Redis                as R


-- WS SUBSCRIPTION

-- | Clients can subscribe to a room identified by it's name.
newtype ChatRoomSubscription = ChatRoomSubscription
    { room :: Text
    } deriving (Show, Read, Eq, Ord, Generic)

instance ToJSON ChatRoomSubscription where
    toJSON = genericToJSON msgJsonOptions
instance FromJSON ChatRoomSubscription where
    parseJSON = genericParseJSON msgJsonOptions

instance WebsocketSubscription ChatRoomSubscription where
    type SubMgmtParams ChatRoomSubscription = R.Connection
    type SubMsgForClient ChatRoomSubscription = ChatRoomWSMsgForClient
    clientMsgSubscription = ChatRoomSubscription . \case
        JoinedRoom RoomMemberChangeData { room } -> room
        LeftRoom   RoomMemberChangeData { room } -> room
        NewMessage NewMessageData { room }       -> room
        MemberList RoomMemberListData { room }   -> room
    type SubMsgForServer ChatRoomSubscription = ChatRoomWSMsgForServer
    serverMsgSubscription = ChatRoomSubscription . \case
        JoinRoom    RoomData { room }        -> room
        LeaveRoom   RoomData { room }        -> room
        SendMessage SendMessageData { room } -> room
    -- | @"chat-room-<room-name>"@
    subscriptionIdentifier ChatRoomSubscription { room } =
        SubscriptionIdentifier $ "chat-room-" <> room
    -- | Inform subscribers about the new user.
    onSubscribe redisConn clientId ChatRoomSubscription { room } =
        sendMessageToSubscription @ChatRoomSubscription redisConn
            $ JoinedRoom
            $ RoomMemberChangeData room clientId
    -- | Inform subscribers the user has left.
    onUnsubscribe redisConn clientId ChatRoomSubscription { room } =
        sendMessageToSubscription @ChatRoomSubscription redisConn
            $ LeftRoom
            $ RoomMemberChangeData room clientId
    isSubscribeMsg = \case
        JoinRoom{} -> True
        _          -> False
    isUnsubscribeMsg = \case
        LeaveRoom{} -> True
        _           -> False

-- | Handle chat room subscription management and any incoming websocket
-- messages.
--
-- TODO: would be cool to explore how we might keep a channel listing
-- (TVar (HashMap Text [UserId])) that is sync'd across all servers so we
-- could send an accurate UserId listing when joining. How do new servers
-- get the latest map?
--
-- Or would each server just keep a local mapping and every server sends
-- that to the client when a client joins?
chatRoomClientMessageHandler
    :: R.Connection -> TVar WebsocketController -> WebsocketHandler
chatRoomClientMessageHandler redisConn wsCtl =
    makeSubscriptionHandler @ChatRoomSubscription wsCtl redisConn
        $ \clientId -> \case
              JoinRoom (RoomData { room }) -> do
                  sendMessage wsCtl clientId $ MemberList $ RoomMemberListData
                      room
                      []
              LeaveRoom   _ -> return ()
              SendMessage (SendMessageData { room, message }) -> do
                  sendMessageToSubscription @ChatRoomSubscription redisConn
                      $ NewMessage
                      $ NewMessageData room clientId message



-- WS SERVER MESSAGES

-- | WebSockets messages from clients for the server.
data ChatRoomWSMsgForServer
    = JoinRoom RoomData
    -- ^ Join a new room
    | LeaveRoom RoomData
    -- ^ Leave a room
    | SendMessage SendMessageData
    -- ^ Send a message to a room
    deriving (Show, Read, Eq, Ord, Generic)

instance ReceivableWSMessage ChatRoomWSMsgForServer
instance HasWSChannelName ChatRoomWSMsgForServer where
    wsChannelName = "chat-room"
instance FromJSON ChatRoomWSMsgForServer where
    parseJSON = genericParseJSON msgJsonOptions

newtype RoomData = RoomData
    { room :: Text
    }
    deriving (Show, Read, Eq, Ord, Generic)
instance FromJSON RoomData where
    parseJSON = genericParseJSON msgDataJsonOptions

data SendMessageData = SendMessageData
    { room    :: Text
    , message :: Text
    }
    deriving (Show, Read, Eq, Ord, Generic)
instance FromJSON SendMessageData where
    parseJSON = genericParseJSON msgDataJsonOptions


-- WS CLIENT MESSAGES

-- | WebSockets messages from servers for the clients.
data ChatRoomWSMsgForClient
    = JoinedRoom RoomMemberChangeData
    -- ^ Someone joined a room you are in
    | LeftRoom RoomMemberChangeData
    -- ^ Someone left a room you are in
    | NewMessage NewMessageData
    -- ^ Someone posted a message to a room you are in
    | MemberList RoomMemberListData
    -- ^ Everyone in a room you just joined.
    deriving (Show, Read, Eq, Ord, Generic)

instance SendableWSMessage ChatRoomWSMsgForClient
instance HasWSChannelName ChatRoomWSMsgForClient where
    wsChannelName = wsChannelName @ChatRoomWSMsgForServer
instance ToJSON  ChatRoomWSMsgForClient where
    toJSON = genericToJSON msgJsonOptions
instance FromJSON ChatRoomWSMsgForClient where
    parseJSON = genericParseJSON msgJsonOptions

data RoomMemberChangeData = RoomMemberChangeData
    { room :: Text
    , user :: UserId
    }
    deriving (Show, Read, Eq, Ord, Generic)
instance ToJSON RoomMemberChangeData where
    toJSON = genericToJSON msgDataJsonOptions
instance FromJSON RoomMemberChangeData where
    parseJSON = genericParseJSON msgDataJsonOptions

data NewMessageData = NewMessageData
    { room    :: Text
    , user    :: UserId
    , message :: Text
    }
    deriving (Show, Read, Eq, Ord, Generic)
instance ToJSON NewMessageData where
    toJSON = genericToJSON msgDataJsonOptions
instance FromJSON NewMessageData where
    parseJSON = genericParseJSON msgDataJsonOptions

data RoomMemberListData = RoomMemberListData
    { room  :: Text
    , users :: [UserId]
    }
    deriving (Show, Read, Eq, Ord, Generic)
instance ToJSON RoomMemberListData where
    toJSON = genericToJSON msgDataJsonOptions
instance FromJSON RoomMemberListData where
    parseJSON = genericParseJSON msgDataJsonOptions
