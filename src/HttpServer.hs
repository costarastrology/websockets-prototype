{-| Minimal HTTP server for poking Redis and serving WebSockets. -}
module HttpServer where

import           Control.Concurrent.STM         ( TVar )
import           Control.Monad                  ( void )
import           Database.Redis                 ( Connection
                                                , runRedis
                                                )
import           Network.HTTP.Types             ( status200
                                                , status404
                                                )
import           Network.Wai                    ( Application
                                                , Request(..)
                                                , responseLBS
                                                )

import           Chat                           ( chatClientMessageHandler )
import           ISCB                           ( publishMessage )
import           Ping                           ( PingInterServerMessage(..) )
import           Sockets                        ( websocketsHandlerWithFallback
                                                )
import           Sockets.Messages               ( WebsocketController
                                                , WebsocketHandler
                                                , makeWebsocketHandler
                                                )


-- | Publish proper ISCB messages for /ping1 & /ping2 routes, expose
-- websockets at /websockets, 404 for everything else.
app :: TVar WebsocketController -> Connection -> Application
app wsController redisConn req respond = case pathInfo req of
    ["ping1"] -> do
        void . runRedis redisConn $ publishMessage SendPing1
        respond $ responseLBS status200 [] ""
    ["ping2"] -> do
        void . runRedis redisConn $ publishMessage SendPing2
        respond $ responseLBS status200 [] ""
    ["websockets"] -> do
        websocketsHandlerWithFallback wsController
                                      (websocketHandlers redisConn)
                                      req
                                      respond
    _ -> respond $ responseLBS status404 [] "invalid path"

-- | Handlers for all our websocket message types.
websocketHandlers :: Connection -> [WebsocketHandler]
websocketHandlers redisConn =
    [makeWebsocketHandler (chatClientMessageHandler redisConn)]
