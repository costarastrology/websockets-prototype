{-| Minimal HTTP server for poking Redis. -}
module HttpServer where

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

import           ISCB


-- | Publish proper messages for /ping1 & /ping2 routes, 404 for everything
-- else.
app :: Connection -> Application
app conn req respond = case pathInfo req of
    ["ping1"] -> do
        void . runRedis conn $ publishMessage SendPing1
        respond $ responseLBS status200 [] ""
    ["ping2"] -> do
        void . runRedis conn $ publishMessage SendPing2
        respond $ responseLBS status200 [] ""
    _ -> respond $ responseLBS status404 [] "invalid path"
