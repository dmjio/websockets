--------------------------------------------------------------------------------
-- | This provides a simple stand-alone server for 'WebSockets' applications.
-- Note that in production you want to use a real webserver such as snap or
-- warp.
{-# LANGUAGE OverloadedStrings #-}
module Network.WebSockets.Server
    ( ServerApp
    , runServer
    , runServerWith
    ) where


--------------------------------------------------------------------------------
import           Control.Concurrent            (forkIO)
import           Control.Exception             (finally)
import           Control.Monad                 (forever)
import           Network.Socket                (Socket)
import qualified Network.Socket                as S
import qualified System.IO.Streams.Attoparsec  as Streams
import qualified System.IO.Streams.Builder     as Streams
import qualified System.IO.Streams.Network     as Streams


--------------------------------------------------------------------------------
import           Network.WebSockets.Connection
import           Network.WebSockets.Http


--------------------------------------------------------------------------------
-- | WebSockets application that can be ran by a server. Once this 'IO' action
-- finishes, the underlying socket is closed automatically.
type ServerApp = PendingConnection -> IO ()


--------------------------------------------------------------------------------
-- | Provides a simple server. This function blocks forever. Note that this
-- is merely provided for quick-and-dirty standalone applications, for real
-- applications, you should use a real server.
runServer :: String     -- ^ Address to bind
          -> Int        -- ^ Port to listen on
          -> ServerApp  -- ^ Application
          -> IO ()      -- ^ Never returns
runServer host port app = runServerWith host port defaultConnectionOptions app


--------------------------------------------------------------------------------
-- | A version of 'runServer' which allows you to customize some options.
runServerWith :: String -> Int -> ConnectionOptions -> ServerApp -> IO ()
runServerWith host port opts app = S.withSocketsDo $ do
    sock  <- S.socket S.AF_INET S.Stream S.defaultProtocol
    _     <- S.setSocketOption sock S.ReuseAddr 1
    host' <- S.inet_addr host
    S.bindSocket sock (S.SockAddrInet (fromIntegral port) host')
    S.listen sock 5
    _ <- forever $ do
        -- TODO: top level handle
        (conn, _) <- S.accept sock
        _         <- forkIO $ finally (runApp conn opts app) (S.sClose conn)
        return ()
    S.sClose sock


--------------------------------------------------------------------------------
runApp :: Socket
       -> ConnectionOptions
       -> ServerApp
       -> IO ()
runApp socket opts app = do
    (sIn, sOut) <- Streams.socketToStreams socket
    bOut        <- Streams.builderStream sOut
    -- TODO: we probably want to send a 40x if the request is bad?
    request     <- Streams.parseFromStream (decodeRequestHead False) sIn
    let pc = PendingConnection
                { pendingOptions  = opts
                , pendingRequest  = request
                , pendingOnAccept = \_ -> return ()
                , pendingIn       = sIn
                , pendingOut      = bOut
                }

    app pc
