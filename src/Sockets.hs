{-| Websockets HTTP handler & message relays.

-}
module Sockets where

import           Control.Concurrent.STM         ( TVar
                                                , atomically
                                                )
import           Control.Exception              ( handle )
import           Control.Monad                  ( forever )
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
                                                , withPingThread
                                                )

import           Sockets.Controller             ( UserId
                                                , WebsocketController
                                                , getConnectedClients
                                                , getSubscriptions
                                                , registerNewClient
                                                , unregisterClient
                                                )
import           Sockets.Messages               ( WebsocketHandler
                                                , handleIncomingWebsocketMessages
                                                )


-- | A request handler that calls the websockets handler or throws a 400
-- error if the request is not a websockets request..
websocketsHandlerWithFallback
    :: TVar WebsocketController
    -> [WebsocketHandler]
    -> Request
    -> (Response -> IO ResponseReceived)
    -> IO ResponseReceived
websocketsHandlerWithFallback wsController messageHandlers = websocketsOr
    connectionOptions
    (websocketsHandler wsController messageHandlers)
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
--  4. Starts a loop to read incoming messages and dispatch them to the
--     appropriate handlers based on it's @channel@ field. This loop is
--     started alongside:
--      * A "ping" thread to keep the connection from timing out.
--      * An exception handler that removes the client from the connection
--        map.
websocketsHandler
    :: TVar WebsocketController
    -> [WebsocketHandler]
    -> PendingConnection
    -> IO ()
websocketsHandler wsController messageHandlers pendingConn = do
    connection <- acceptRequest pendingConn
    clientId   <- registerNewClient wsController connection
    logConnected clientId
    withPingThread connection 30 (return ())
        $ withCleanup clientId
        $ forever
        $ handleMessages clientId connection
  where
    logConnected :: UserId -> IO ()
    logConnected clientId = do
        putStrLn $ "[WebSocket] [" <> show clientId <> "] Connected"
        connectedIds <- atomically $ getConnectedClients wsController
        activeSubs   <- atomically $ getSubscriptions wsController
        putStrLn $ "[WebSocket] New Client List: " <> show connectedIds
        putStrLn $ "[WebSocket] New Subscription List: " <> show activeSubs
    withCleanup :: UserId -> IO () -> IO ()
    withCleanup clientId = handle $ \(_ :: ConnectionException) -> do
        unregisterClient wsController clientId
        connectedIds <- atomically $ getConnectedClients wsController
        activeSubs   <- atomically $ getSubscriptions wsController
        putStrLn $ "[WebSocket] [" <> show clientId <> "] Disconnected"
        putStrLn $ "[WebSocket] New Client List: " <> show connectedIds
        putStrLn $ "[WebSocket] New Subscription List: " <> show activeSubs
    handleMessages :: UserId -> Connection -> IO ()
    handleMessages clientId connection = do
        receiveData connection
            >>= handleIncomingWebsocketMessages clientId messageHandlers
