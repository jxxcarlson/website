{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import Web.Scotty
import Web.Scotty.Internal.Types (StatusError)
import Network.Wai (Middleware)
import Network.Wai.Middleware.Cors
    ( cors
    , CorsResourcePolicy(..)
    , simpleCorsResourcePolicy
    , simpleHeaders
    )
import Network.HTTP.Types.Status (status400, status404)
import Network.HTTP.Types.Method (methodGet, methodPost, methodOptions)
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import GHC.Generics (Generic)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import System.Directory (getHomeDirectory, getCurrentDirectory, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Text.Pandoc (runPure, readMarkdown, writeHtml5String, def)
import Text.Pandoc.Options (ReaderOptions(..), WriterOptions(..), HTMLMathMethod(..), Extension(..), enableExtension)
import qualified Data.Map as M
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.IORef
import System.Process (createProcess, proc, terminateProcess, interruptProcessGroupOf, getProcessExitCode, ProcessHandle, CreateProcess(..))
import Control.Exception (try, SomeException)
import Data.List (sortBy, isPrefixOf)
import Data.Ord (Down(..))

import Grab (grabURL, GrabResult(..), OutputFormat(..))
import Scripta (processScripta, LinkMap)
import Utils (preprocessScriptaImport, stripFirstLine, stripFirstLineTags)

-- | JSON request body for /api/grab
data GrabRequest = GrabRequest
    { url    :: String
    , format :: String
    , tags   :: Maybe String
    } deriving (Show, Generic)

instance FromJSON GrabRequest

-- | Parse the format string into an OutputFormat
parseFormat :: String -> Maybe OutputFormat
parseFormat "md"      = Just Markdown
parseFormat "scripta" = Just Scripta
parseFormat _         = Nothing

-- | Dashboard process management state
data ServerState = ServerState
    { devServerProc :: Maybe ProcessHandle
    , watchProc     :: Maybe ProcessHandle
    }

-- | JSON-serializable process status
data ProcessInfo = ProcessInfo
    { devServerRunning :: Bool
    , watchRunning     :: Bool
    , lastDeploy       :: Maybe String
    } deriving (Show, Generic)

instance ToJSON ProcessInfo

-- | Check if a ProcessHandle is still running
isRunning :: Maybe ProcessHandle -> IO Bool
isRunning Nothing = return False
isRunning (Just ph) = do
    ec <- getProcessExitCode ph
    return $ case ec of
        Nothing -> True   -- still running
        Just _  -> False  -- exited

-- | Read last deploy time from /tmp/archive_watcher_lastdeploy
getLastDeploy :: IO (Maybe String)
getLastDeploy = do
    result <- try (readFile "/tmp/archive_watcher_lastdeploy") :: IO (Either SomeException String)
    case result of
        Left _  -> return Nothing
        Right s -> return (Just (take 20 s))

-- | Start dev server: kill port 8000, rebuild site, then start site watch
startDevServer :: IORef ServerState -> IO (Either String String)
startDevServer ref = do
    st <- readIORef ref
    running <- isRunning st.devServerProc
    if running
        then return (Left "Dev server is already running")
        else do
            cwd <- getCurrentDirectory
            -- Kill old server, build, rebuild, then exec into site watch.
            -- 'exec' replaces the shell so our ProcessHandle tracks the
            -- long-running site watch process directly.
            let cmd = "lsof -ti:8000 | xargs kill -9 2>/dev/null; sleep 1; "
                   ++ "ulimit -n 10240; "
                   ++ "stack build && stack exec site rebuild && exec stack exec site watch"
                cp = (proc "sh" ["-c", cmd])
                    { cwd = Just cwd
                    , create_group = True
                    }
            (_, _, _, ph) <- createProcess cp
            writeIORef ref st { devServerProc = Just ph }
            return (Right "Dev server started")

-- | Stop dev server: kill process group + kill port 8000
stopDevServer :: IORef ServerState -> IO (Either String String)
stopDevServer ref = do
    st <- readIORef ref
    case st.devServerProc of
        Nothing -> return (Left "Dev server is not running")
        Just ph -> do
            interruptProcessGroupOf ph
            _ <- createProcess (proc "sh" ["-c", "lsof -ti:8000 | xargs kill -9 2>/dev/null"])
            writeIORef ref st { devServerProc = Nothing }
            return (Right "Dev server stopped")

-- | Start watch: runs "sh scripts/watch_and_deploy.sh"
startWatch :: IORef ServerState -> IO (Either String String)
startWatch ref = do
    st <- readIORef ref
    running <- isRunning st.watchProc
    if running
        then return (Left "Watch process is already running")
        else do
            cwd <- getCurrentDirectory
            let cp = (proc "sh" [cwd </> "scripts" </> "watch_and_deploy.sh"])
                    { cwd = Just cwd
                    , create_group = True
                    }
            (_, _, _, ph) <- createProcess cp
            writeIORef ref st { watchProc = Just ph }
            return (Right "Watch process started")

-- | Stop watch: kill process group (includes fswatch children)
stopWatch :: IORef ServerState -> IO (Either String String)
stopWatch ref = do
    st <- readIORef ref
    case st.watchProc of
        Nothing -> return (Left "Watch process is not running")
        Just ph -> do
            interruptProcessGroupOf ph
            writeIORef ref st { watchProc = Nothing }
            return (Right "Watch process stopped")

-- | Deploy: runs "sh scripts/deploy.sh"
runDeploy :: IO (Either String String)
runDeploy = do
    cwd <- getCurrentDirectory
    let cp = (proc "sh" [cwd </> "scripts" </> "deploy.sh"])
            { cwd = Just cwd
            }
    _ <- createProcess cp
    return (Right "Deploy started")

main :: IO ()
main = do
    putStrLn "Grab server starting on port 8080..."
    stateRef <- newIORef (ServerState Nothing Nothing)
    scotty 8080 $ do
        middleware corsMiddleware

        -- Health check
        get "/api/health" $ do
            text "ok"

        -- Grab endpoint
        post "/api/grab" $ do
            req <- jsonData :: ActionM GrabRequest
            case parseFormat req.format of
                Nothing -> do
                    status status400
                    json $ object ["error" .= ("Invalid format. Use 'md' or 'scripta'." :: String)]
                Just fmt -> do
                    result <- liftIO $ grabURL req.url fmt req.tags
                    case result of
                        Left err -> do
                            status status400
                            json $ object ["error" .= err]
                        Right grabResult -> do
                            setHeader "Content-Type" "text/plain; charset=utf-8"
                            setHeader "X-Filename" (TL.pack grabResult.grabFilename)
                            text (TL.pack grabResult.grabContent)

        -- Grab and save directly to The Archive
        post "/api/grab-to-archive" $ do
            req <- jsonData :: ActionM GrabRequest
            let fmt = Scripta  -- Archive notes use Scripta format
            result <- liftIO $ grabURL req.url fmt req.tags
            case result of
                Left err -> do
                    status status400
                    json $ object ["error" .= err]
                Right grabResult -> do
                    saveResult <- liftIO $ saveToArchive grabResult.grabTitle grabResult.grabContent
                    case saveResult of
                        Left err -> do
                            status status400
                            json $ object ["error" .= err]
                        Right filename -> do
                            json $ object ["filename" .= filename, "title" .= grabResult.grabTitle]

        -- Dashboard: process status
        get "/api/status" $ do
            st <- liftIO $ readIORef stateRef
            devRunning <- liftIO $ isRunning st.devServerProc
            wRunning <- liftIO $ isRunning st.watchProc
            deploy <- liftIO getLastDeploy
            json $ ProcessInfo devRunning wRunning deploy

        -- Dashboard: start dev server
        post "/api/start-dev" $ do
            result <- liftIO $ startDevServer stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: stop dev server
        post "/api/stop-dev" $ do
            result <- liftIO $ stopDevServer stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: start watch process
        post "/api/start-watch" $ do
            result <- liftIO $ startWatch stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: stop watch process
        post "/api/stop-watch" $ do
            result <- liftIO $ stopWatch stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: run deploy
        post "/api/deploy" $ do
            result <- liftIO runDeploy
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard HTML page
        get "/dashboard" $ do
            setHeader "Content-Type" "text/html; charset=utf-8"
            html dashboardHtml

        -- Preview endpoint: render archive file, or show file listing if no ?file= param
        get "/api/preview" $ do
            home <- liftIO getHomeDirectory
            let archivePath = home </> "Dropbox" </> "theARCHIVE"
            fileParam <- (Right <$> (queryParam "file" :: ActionM String))
                         `rescue` (\(_ :: StatusError) -> return (Left ()))
            case fileParam of
                Left _ -> do
                    -- No file param: show listing page
                    files <- liftIO $ listArchiveFiles archivePath
                    setHeader "Content-Type" "text/html; charset=utf-8"
                    Web.Scotty.html (TL.pack $ previewListPage files)
                Right name -> do
                    let fullPath = archivePath </> name
                    exists <- liftIO $ doesFileExist fullPath
                    if not exists
                        then do
                            status status404
                            json (object ["error" .= ("File not found" :: String)])
                        else do
                            content <- liftIO $ readFile fullPath
                            _ <- liftIO $ return $! length content
                            case renderPreview content of
                                Left err -> do
                                    status status400
                                    json (object ["error" .= err])
                                Right renderedHtml -> do
                                    setHeader "Content-Type" "text/html; charset=utf-8"
                                    Web.Scotty.html (TL.pack $ previewPage name renderedHtml)

-- | Dashboard HTML served inline
dashboardHtml :: TL.Text
dashboardHtml = TL.pack $ unlines
    [ "<!DOCTYPE html>"
    , "<html lang=\"en\">"
    , "<head>"
    , "<meta charset=\"UTF-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
    , "<title>Site Dashboard</title>"
    , "<style>"
    , "  :root {"
    , "    --bg: #2a2d2b;"
    , "    --card-bg: #31342f;"
    , "    --card-border: #3d403a;"
    , "    --text: #b5b2aa;"
    , "    --text-muted: #8a877f;"
    , "    --text-dim: #76736b;"
    , "    --heading: #928f87;"
    , "    --subheading: #9e9b93;"
    , "    --btn-bg: #363930;"
    , "    --btn-text: #a09d95;"
    , "    --btn-border: #4a4d44;"
    , "    --btn-hover: #3d403a;"
    , "    --green: #8aaa91;"
    , "    --green-border: #637a68;"
    , "    --green-hover: #353d37;"
    , "    --red: #ab8e8a;"
    , "    --red-border: #7a6562;"
    , "    --red-hover: #3d3533;"
    , "    --blue: #8e99a8;"
    , "    --blue-border: #636b7a;"
    , "    --blue-hover: #353840;"
    , "    --dot-on: #7a9e85;"
    , "    --dot-off: #555750;"
    , "  }"
    , "  * { margin: 0; padding: 0; box-sizing: border-box; }"
    , "  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;"
    , "         background: var(--bg); color: var(--text); padding: 2rem; }"
    , "  h1 { text-align: center; margin-bottom: 2rem; color: var(--heading); font-size: 1.4rem; font-weight: 500; }"
    , "  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));"
    , "          gap: 1.5rem; max-width: 900px; margin: 0 auto; }"
    , "  .card { background: var(--card-bg); border-radius: 8px; padding: 1.5rem;"
    , "          border: 1px solid var(--card-border); }"
    , "  .card h2 { font-size: 0.95rem; margin-bottom: 1rem; color: var(--subheading); font-weight: 500; }"
    , "  .status-row { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }"
    , "  .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }"
    , "  .dot.on  { background: var(--dot-on); }"
    , "  .dot.off { background: var(--dot-off); }"
    , "  .status-label { font-size: 0.85rem; color: var(--text-muted); }"
    , "  button { padding: 0.45rem 1.1rem; border: 1px solid var(--btn-border); border-radius: 4px; cursor: pointer;"
    , "           font-size: 0.8rem; font-weight: 500; transition: background 0.2s; background: var(--btn-bg); color: var(--btn-text); }"
    , "  button:hover { background: var(--btn-hover); }"
    , "  button:disabled { opacity: 0.35; cursor: not-allowed; }"
    , "  .btn-start { border-color: var(--green-border); color: var(--green); }"
    , "  .btn-start:hover { background: var(--green-hover); }"
    , "  .btn-stop  { border-color: var(--red-border); color: var(--red); }"
    , "  .btn-stop:hover { background: var(--red-hover); }"
    , "  .btn-deploy { border-color: var(--blue-border); color: var(--blue); }"
    , "  .btn-deploy:hover { background: var(--blue-hover); }"
    , "  .deploy-info { font-size: 0.8rem; color: var(--text-dim); margin-top: 0.75rem; }"
    , "  .msg { font-size: 0.8rem; color: var(--text-dim); margin-top: 0.5rem; min-height: 1.2em; }"
    , "</style>"
    , "</head>"
    , "<body>"
    , "<h1>Site Dashboard</h1>"
    , "<div class=\"grid\">"
    , ""
    , "  <div class=\"card\">"
    , "    <h2>Dev Server</h2>"
    , "    <div class=\"status-row\">"
    , "      <div id=\"dev-dot\" class=\"dot off\"></div>"
    , "      <span id=\"dev-label\" class=\"status-label\">Stopped</span>"
    , "    </div>"
    , "    <button id=\"dev-start\" class=\"btn-start\" onclick=\"postAction('/api/start-dev', 'dev-msg')\">Start</button>"
    , "    <button id=\"dev-stop\" class=\"btn-stop\" onclick=\"postAction('/api/stop-dev', 'dev-msg')\">Stop</button>"
    , "    <div id=\"dev-msg\" class=\"msg\"></div>"
    , "  </div>"
    , ""
    , "  <div class=\"card\">"
    , "    <h2>Watch &amp; Deploy</h2>"
    , "    <div class=\"status-row\">"
    , "      <div id=\"watch-dot\" class=\"dot off\"></div>"
    , "      <span id=\"watch-label\" class=\"status-label\">Stopped</span>"
    , "    </div>"
    , "    <button id=\"watch-start\" class=\"btn-start\" onclick=\"postAction('/api/start-watch', 'watch-msg')\">Start</button>"
    , "    <button id=\"watch-stop\" class=\"btn-stop\" onclick=\"postAction('/api/stop-watch', 'watch-msg')\">Stop</button>"
    , "    <div id=\"watch-msg\" class=\"msg\"></div>"
    , "  </div>"
    , ""
    , "  <div class=\"card\">"
    , "    <h2>Deploy</h2>"
    , "    <button class=\"btn-deploy\" onclick=\"postAction('/api/deploy', 'deploy-msg')\">Deploy Now</button>"
    , "    <div id=\"deploy-msg\" class=\"msg\"></div>"
    , "    <div id=\"last-deploy\" class=\"deploy-info\"></div>"
    , "  </div>"
    , ""
    , "</div>"
    , ""
    , "<script>"
    , "function updateStatus() {"
    , "  fetch('/api/status')"
    , "    .then(r => r.json())"
    , "    .then(d => {"
    , "      setDot('dev', d.devServerRunning);"
    , "      setDot('watch', d.watchRunning);"
    , "      const el = document.getElementById('last-deploy');"
    , "      if (d.lastDeploy) {"
    , "        const ts = parseInt(d.lastDeploy);"
    , "        if (!isNaN(ts)) {"
    , "          el.textContent = 'Last deploy: ' + new Date(ts * 1000).toLocaleString();"
    , "        } else {"
    , "          el.textContent = 'Last deploy: ' + d.lastDeploy;"
    , "        }"
    , "      } else {"
    , "        el.textContent = 'No deploy info';"
    , "      }"
    , "    })"
    , "    .catch(() => {});"
    , "}"
    , ""
    , "function setDot(prefix, running) {"
    , "  const dot = document.getElementById(prefix + '-dot');"
    , "  const label = document.getElementById(prefix + '-label');"
    , "  dot.className = running ? 'dot on' : 'dot off';"
    , "  label.textContent = running ? 'Running' : 'Stopped';"
    , "}"
    , ""
    , "function postAction(url, msgId) {"
    , "  const el = document.getElementById(msgId);"
    , "  el.textContent = 'Working...';"
    , "  fetch(url, { method: 'POST' })"
    , "    .then(r => r.json())"
    , "    .then(d => {"
    , "      el.textContent = d.message || d.status;"
    , "      setTimeout(updateStatus, 1000);"
    , "    })"
    , "    .catch(e => { el.textContent = 'Error: ' + e.message; });"
    , "}"
    , ""
    , "updateStatus();"
    , "setInterval(updateStatus, 5000);"
    , "</script>"
    , "</body>"
    , "</html>"
    ]

-- | Save content to ~/Dropbox/theARCHIVE with a Zettelkasten ID filename
saveToArchive :: String -> String -> IO (Either String String)
saveToArchive title content = do
    home <- getHomeDirectory
    let archiveDir = home </> "Dropbox" </> "theARCHIVE"
    now <- getCurrentTime
    let zettelId = formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
        filename = zettelId ++ "-" ++ sanitizeTitle title ++ ".txt"
        filepath = archiveDir </> filename
    writeFile filepath (title ++ "\n\n" ++ content)
    return $ Right filename

-- | Sanitize title for use in filename
sanitizeTitle :: String -> String
sanitizeTitle = take 40 . map dashify . filter isValid
  where
    isValid c = c `elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " -")
    dashify ' ' = '-'
    dashify c   = c

-- | List .txt files in archive, sorted newest first, with titles
listArchiveFiles :: FilePath -> IO [(String, String)]
listArchiveFiles dir = do
    entries <- listDirectory dir
    let txtFiles = filter (\f -> ".txt" `isSuffixOf` f) entries
        sorted = sortBy (\a b -> compare (Down a) (Down b)) txtFiles
    forM sorted $ \f -> do
        content <- readFile (dir </> f)
        let title = case lines content of
                (l:_) | not (null l) -> l
                _ -> f
        _ <- return $! length title
        return (f, title)
  where
    isSuffixOf suffix s = reverse suffix `isPrefixOf` reverse s

-- | HTML page listing archive files with search
previewListPage :: [(String, String)] -> String
previewListPage files = unlines
    [ "<!DOCTYPE html>"
    , "<html lang=\"en\"><head>"
    , "<meta charset=\"UTF-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
    , "<title>Archive Preview</title>"
    , "<style>"
    , "  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;"
    , "         max-width: 700px; margin: 0 auto; padding: 2rem; background: #fafafa; color: #333; }"
    , "  h1 { font-size: 1.3rem; color: #555; margin-bottom: 1rem; }"
    , "  input { width: 100%; padding: 0.5rem; font-size: 1rem; border: 1px solid #ccc;"
    , "          border-radius: 4px; margin-bottom: 1rem; box-sizing: border-box; }"
    , "  input:focus { outline: none; border-color: #888; }"
    , "  ul { list-style: none; padding: 0; }"
    , "  li { padding: 0.4rem 0; border-bottom: 1px solid #eee; }"
    , "  li a { color: #2266cc; text-decoration: none; }"
    , "  li a:hover { text-decoration: underline; }"
    , "  .filename { color: #999; font-size: 0.8rem; margin-left: 0.5rem; }"
    , "  .count { color: #999; font-size: 0.85rem; margin-bottom: 0.5rem; }"
    , "</style>"
    , "</head><body>"
    , "<h1>Archive Preview</h1>"
    , "<input type=\"text\" id=\"search\" placeholder=\"Search files...\" autofocus>"
    , "<div class=\"count\" id=\"count\">" ++ show (length files) ++ " files</div>"
    , "<ul id=\"file-list\">"
    , concatMap renderFileItem files
    , "</ul>"
    , "<script>"
    , "var search = document.getElementById('search');"
    , "var items = document.querySelectorAll('#file-list li');"
    , "var countEl = document.getElementById('count');"
    , "search.addEventListener('input', function() {"
    , "  var q = this.value.toLowerCase();"
    , "  var visible = 0;"
    , "  items.forEach(function(li) {"
    , "    var match = li.textContent.toLowerCase().indexOf(q) >= 0;"
    , "    li.style.display = match ? '' : 'none';"
    , "    if (match) visible++;"
    , "  });"
    , "  countEl.textContent = visible + ' files';"
    , "});"
    , "</script>"
    , "</body></html>"
    ]
  where
    renderFileItem (filename, title) =
        "<li><a href=\"/api/preview?file=" ++ filename ++ "\">"
        ++ escapeHtml title ++ "</a>"
        ++ "<span class=\"filename\">" ++ filename ++ "</span></li>\n"
    escapeHtml [] = []
    escapeHtml ('<':xs) = "&lt;" ++ escapeHtml xs
    escapeHtml ('>':xs) = "&gt;" ++ escapeHtml xs
    escapeHtml ('&':xs) = "&amp;" ++ escapeHtml xs
    escapeHtml ('"':xs) = "&quot;" ++ escapeHtml xs
    escapeHtml (c:xs) = c : escapeHtml xs

-- | Render archive file content through Scripta→Pandoc pipeline
renderPreview :: String -> Either String String
renderPreview content =
    let processed = processScripta M.empty
                  $ stripFirstLineTags
                  $ stripFirstLine
                  $ preprocessScriptaImport content
        readerOpts = def { readerExtensions = enableExtension Ext_raw_html
                                            $ enableExtension Ext_markdown_in_html_blocks
                                            $ enableExtension Ext_tex_math_dollars
                                            $ enableExtension Ext_tex_math_double_backslash
                                            $ readerExtensions (def :: ReaderOptions) }
        writerOpts = def { writerHTMLMathMethod = MathJax ""
                         , writerExtensions = enableExtension Ext_raw_html
                                            $ writerExtensions (def :: WriterOptions) }
        result = runPure $ do
            doc <- readMarkdown readerOpts (T.pack processed)
            writeHtml5String writerOpts doc
    in case result of
        Left err  -> Left (show err)
        Right h -> Right (T.unpack h)

-- | Wrap rendered HTML in a full preview page with KaTeX and auto-refresh
previewPage :: String -> String -> String
previewPage filename bodyHtml = unlines
    [ "<!DOCTYPE html>"
    , "<html lang=\"en\">"
    , "<head>"
    , "<meta charset=\"UTF-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
    , "<title>Preview: " ++ filename ++ "</title>"
    , "<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css\">"
    , "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js\"></script>"
    , "<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js\""
    , "  onload=\"renderMathInElement(document.body, {"
    , "    delimiters: ["
    , "      {left: '\\\\[', right: '\\\\]', display: true},"
    , "      {left: '\\\\(', right: '\\\\)', display: false}"
    , "    ]"
    , "  });\"></script>"
    , "<style>"
    , "  body { font-family: Georgia, 'Times New Roman', serif; max-width: 700px;"
    , "         margin: 0 auto; padding: 2rem; line-height: 1.6; color: #333; background: #fafafa; }"
    , "  h1, h2, h3 { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }"
    , "  img { max-width: 100%; }"
    , "  pre { background: #f0f0f0; padding: 1em; overflow-x: auto; border-radius: 4px; }"
    , "  code { background: #f0f0f0; padding: 0.15em 0.3em; border-radius: 3px; font-size: 0.9em; }"
    , "  pre code { background: none; padding: 0; }"
    , "  blockquote { border-left: 3px solid #ccc; margin-left: 0; padding-left: 1em; color: #555; }"
    , "  .equation { margin: 1.5em 0; text-align: center; }"
    , "  .theorem { border-left: 3px solid #666; padding: 0.5em 1em; margin: 1em 0; background: #f5f5f0; }"
    , "  .theorem-label { font-weight: bold; font-style: italic; }"
    , "  .quotation { margin-left: 2em; font-style: italic; color: #555; }"
    , "  .quotation-title { margin-left: 2em; margin-bottom: 0.25em; }"
    , "  .bibitem { margin: 0.5em 0; padding-left: 3em; text-indent: -3em; }"
    , "  .bibitem-label { font-weight: bold; }"
    , "  a { color: #2266cc; }"
    , "  .preview-bar { position: fixed; top: 0; left: 0; right: 0; background: #333; color: #aaa;"
    , "                  padding: 4px 12px; font-size: 12px; font-family: monospace; z-index: 1000; }"
    , "  .preview-bar .filename { color: #ddd; }"
    , "</style>"
    , "</head>"
    , "<body>"
    , "<div class=\"preview-bar\">Preview: <span class=\"filename\">" ++ filename ++ "</span></div>"
    , "<div style=\"margin-top: 2rem;\">"
    , bodyHtml
    , "</div>"
    , "<script>"
    , "(function() {"
    , "  var currentFile = '" ++ filename ++ "';"
    , "  setInterval(function() {"
    , "    fetch('/api/preview?file=' + encodeURIComponent(currentFile))"
    , "      .then(function(r) { return r.text(); })"
    , "      .then(function(html) {"
    , "        var parser = new DOMParser();"
    , "        var doc = parser.parseFromString(html, 'text/html');"
    , "        var newContent = doc.querySelector('body > div:nth-child(2)');"
    , "        var oldContent = document.querySelector('body > div:nth-child(2)');"
    , "        if (newContent && oldContent && newContent.innerHTML !== oldContent.innerHTML) {"
    , "          oldContent.innerHTML = newContent.innerHTML;"
    , "          if (typeof renderMathInElement === 'function') {"
    , "            renderMathInElement(oldContent, {"
    , "              delimiters: ["
    , "                {left: '\\\\[', right: '\\\\]', display: true},"
    , "                {left: '\\\\(', right: '\\\\)', display: false}"
    , "              ]"
    , "            });"
    , "          }"
    , "        }"
    , "      })"
    , "      .catch(function() {});"
    , "  }, 2000);"
    , "})();"
    , "</script>"
    , "</body>"
    , "</html>"
    ]

-- | CORS middleware allowing all origins
corsMiddleware :: Middleware
corsMiddleware = cors $ const $ Just policy
  where
    policy = simpleCorsResourcePolicy
        { corsOrigins = Nothing  -- Allow all origins
        , corsMethods = [methodGet, methodPost, methodOptions]
        , corsRequestHeaders = simpleHeaders ++ ["Content-Type"]
        , corsExposedHeaders = Just ["X-Filename"]
        }
