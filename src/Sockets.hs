{-# LANGUAGE ScopedTypeVariables #-}
{-| Websockets HTTP handler & message relays.

-}
module Sockets where

import           Control.Concurrent.STM         ( STM
                                                , TVar
                                                , atomically
                                                , modifyTVar
                                                , newTVarIO
                                                , readTVar
                                                , readTVarIO
                                                )
import           Control.Exception              ( handle )
import           Control.Monad                  ( forM_
                                                , forever
                                                )
import           Network.HTTP.Types             ( status400 )
import           Network.Wai                    ( Application
                                                , Request
                                                , Response
                                                , ResponseReceived
                                                , responseLBS
                                                )
import           Network.Wai.Handler.WebSockets ( websocketsOr )
import           Network.WebSockets             ( CompressionOptions(..)
                                                , Connection
                                                , ConnectionException
                                                , ConnectionOptions(..)
                                                , PendingConnection
                                                , acceptRequest
                                                , defaultConnectionOptions
                                                , defaultPermessageDeflate
                                                , receiveData
                                                , sendTextData
                                                , withPingThread
                                                )
import           Numeric.Natural                ( Natural )

import qualified Data.ByteString.Char8         as BC
import qualified Data.ByteString.Lazy          as LBS
import qualified Data.Map.Strict               as M


-- | A request handler that calls the websockets handler or throws a 400
-- error if the request is not a websockets request..
websocketsHandlerWithFallback
    :: TVar ConnectionMap
    -> Request
    -> (Response -> IO ResponseReceived)
    -> IO ResponseReceived
websocketsHandlerWithFallback connMap = websocketsOr
    connectionOptions
    (websocketsHandler connMap)
    fallbackRoute
  where
    -- Enable compression of websocket messages.
    connectionOptions :: ConnectionOptions
    connectionOptions = defaultConnectionOptions
        { connectionCompressionOptions = PermessageDeflateCompression
                                             defaultPermessageDeflate
        }
    -- Return a 400 if we get hit with a non-websockets request.
    fallbackRoute :: Application
    fallbackRoute _ respond =
        respond $ responseLBS status400 [] "Expected a WebSockets request."


-- | The handler for all websocket connections.
--
-- It:
--  1. Accepts the incoming connection.
--  2. Generates a client ID & adds the ID+Connection pair to the
--     connection map.
--  3. Logs the new connection & list of connected clients
--  4. Starts a loop to read incoming messages. This loop is started
--     alongside:
--      * A "ping" thread to keep the connection from timing out.
--      * An exception handler that removes the client from the connection
--        map.
--  5. The loop simply waits for a new message & prints it out.
websocketsHandler :: TVar ConnectionMap -> PendingConnection -> IO ()
websocketsHandler connMap pendingConn = do
    connection <- acceptRequest pendingConn
    clientId   <- atomically $ registerNewClient connMap connection
    logConnected clientId
    withPingThread connection 30 (return ())
        $   withCleanup clientId
        $   forever
        $   receiveData connection
        >>= BC.putStrLn
        .   (("[WebSocket] [" <> BC.pack (show clientId) <> "] ") <>)
  where
    logConnected :: UserId -> IO ()
    logConnected clientId = do
        putStrLn $ "[WebSocket] [" <> show clientId <> "] Connected"
        connectedIds <- M.keys . cmMap <$> readTVarIO connMap
        putStrLn $ "[WebSocket] New Client List: " <> show connectedIds
    withCleanup :: UserId -> IO () -> IO ()
    withCleanup clientId = handle $ \(_ :: ConnectionException) -> do
        connectedIds <- atomically $ do
            unregisterClient connMap clientId
            M.keys . cmMap <$> readTVar connMap
        putStrLn $ "[WebSocket] [" <> show clientId <> "] Disconnected"
        putStrLn $ "[WebSocket] New Client List: " <> show connectedIds


-- | Placeholder type for our @user.id@ database column.
type UserId = Natural

-- | WebSocket connection state for a single server instance.
data ConnectionMap = ConnectionMap
    { cmNextClientId :: UserId
    -- ^ We use this to accept & identify any websocket connection. In
    -- reality, we should be inspecting the request headers, decoding the
    -- Auth Token into a DB-backed 'UserId', & rejecting the connection
    -- when authorization fails.
    , cmMap          :: M.Map UserId Connection
    -- ^ The Users/Connections that a server instance knows about.
    }

-- | Build an empty connection map, initialize the first client ID to @1@,
-- and stick it all in a TVar.
initializeConnectionMap :: IO (TVar ConnectionMap)
initializeConnectionMap =
    newTVarIO ConnectionMap { cmNextClientId = 1, cmMap = M.empty }

-- | Add a new connection to the user mapping, assigning & returning a new
-- UserId.
registerNewClient :: TVar ConnectionMap -> Connection -> STM UserId
registerNewClient connMapTVar newConnection = do
    clientId <- cmNextClientId <$> readTVar connMapTVar
    modifyTVar connMapTVar $ \connMap -> connMap
        { cmNextClientId = succ $ cmNextClientId connMap
        , cmMap          = M.insert clientId newConnection $ cmMap connMap
        }
    return clientId

-- | Remove a client from the connection map.
unregisterClient :: TVar ConnectionMap -> UserId -> STM ()
unregisterClient connMapTVar clientId = modifyTVar connMapTVar
    $ \connMap -> connMap { cmMap = M.delete clientId $ cmMap connMap }

-- | Send a message to the client with the given ID.
sendMessageToClient :: TVar ConnectionMap -> UserId -> LBS.ByteString -> IO ()
sendMessageToClient connMapTVar clientId message = do
    mbClientConnection <- M.lookup clientId . cmMap <$> readTVarIO connMapTVar
    forM_ mbClientConnection $ \c -> sendTextData c message
