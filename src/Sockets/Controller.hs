{-| A websockets connection controller along with querying, sending,
& manipulation functions.

TODO: by consolidating this module w/ 'Sockets.Messages', we can remove the
"raw" message sending functions. Consolidation may be the cleaner solve
when allowing users to subscribe to channels - that requires another map
that we'd want to maintain here.

-}
module Sockets.Controller
    ( UserId
    , WebsocketController
    , initializeWebsocketsController
    , registerNewClient
    , unregisterClient
    , getConnectedClients
    , sendRawMessageToClient
    , broadcastRawMessage
    ) where

import           Control.Concurrent.STM         ( STM
                                                , TVar
                                                , atomically
                                                , modifyTVar
                                                , newTVarIO
                                                , readTVar
                                                , readTVarIO
                                                )
import           Control.Monad                  ( forM_ )
import           Data.UUID                      ( UUID )
import           Data.UUID.V4                   ( nextRandom )
import           Network.WebSockets             ( Connection
                                                , sendTextData
                                                )

import qualified Data.ByteString.Lazy          as LBS
import qualified Data.Map.Strict               as M


-- | Placeholder type for our @user.id@ database column.
--
-- We use this to accept & identify _any_ websocket connection. In reality,
-- we should be inspecting the request headers, decoding the Auth Token
-- into a DB-backed 'UserId', & rejecting the connection when authorization
-- fails. We should see if putting the websockets route under a Servant
-- @AuthProtect@ will do all of the above work for us.
type UserId = UUID

-- | WebSocket connection state for a single server instance.
newtype WebsocketController = WebsocketController
    { wscConnMap :: M.Map UserId Connection
    -- ^ The Users/Connections that a server instance knows about.
    }

-- | Build an empty connection map, initialize the first client ID to @1@,
-- and stick it all in a TVar.
initializeWebsocketsController :: IO (TVar WebsocketController)
initializeWebsocketsController =
    newTVarIO WebsocketController { wscConnMap = M.empty }

-- | Add a new connection to the user mapping, assigning & returning a new
-- UserId.
registerNewClient :: TVar WebsocketController -> Connection -> IO UserId
registerNewClient contrTVar newConnection = do
    clientId <- nextRandom
    atomically . modifyTVar contrTVar $ \controller -> controller
        { wscConnMap = M.insert clientId newConnection $ wscConnMap controller
        }
    return clientId

-- | Remove a client from the connection map.
unregisterClient :: TVar WebsocketController -> UserId -> STM ()
unregisterClient contrTVar clientId = modifyTVar contrTVar $ \controller ->
    controller { wscConnMap = M.delete clientId $ wscConnMap controller }

-- | Retrieve all clients in the connection map.
getConnectedClients :: TVar WebsocketController -> STM [UserId]
getConnectedClients = fmap (M.keys . wscConnMap) . readTVar

-- | Send a message to the client with the given ID.
sendRawMessageToClient
    :: TVar WebsocketController -> UserId -> LBS.ByteString -> IO ()
sendRawMessageToClient contrTVar clientId message = do
    mbClientConnection <-
        M.lookup clientId . wscConnMap <$> readTVarIO contrTVar
    forM_ mbClientConnection $ \c -> sendTextData c message

-- | Send a message to all connected clients.
broadcastRawMessage :: TVar WebsocketController -> LBS.ByteString -> IO ()
broadcastRawMessage contrTVar message = do
    allClients <- M.elems . wscConnMap <$> readTVarIO contrTVar
    forM_ allClients $ flip sendTextData message
