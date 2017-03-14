{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RecordWildCards #-}

module Zifter
    ( ziftWith
    , ziftWithSetup
    , preprocessor
    , checker
    , precheck
    , ziftP
    , recursiveZift
    , module Zifter.Script.Types
    ) where

import Control.Concurrent (newEmptyMVar, putMVar, tryTakeMVar)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.STM
       (newTChanIO, tryReadTChan, readTChan, writeTChan, atomically)
import Control.Monad
import Path
import Path.IO
import Safe
import System.Console.ANSI
import qualified System.Directory as D
       (canonicalizePath, setPermissions, getPermissions,
        setOwnerExecutable)
import System.Environment (getProgName)
import System.Exit (die)
import qualified System.FilePath as FP (splitPath, joinPath)
import System.IO
       (hSetBuffering, BufferMode(NoBuffering), stderr, stdout, hFlush)

import Zifter.OptParse
import Zifter.Recurse
import Zifter.Script
import Zifter.Script.Types
import Zifter.Setup
import Zifter.Zift

ziftWith :: ZiftScript () -> IO ()
ziftWith = renderZiftScript >=> (ziftWithSetup . snd)

ziftWithSetup :: ZiftSetup -> IO ()
ziftWithSetup setup = do
    hSetBuffering stdout NoBuffering
    hSetBuffering stderr NoBuffering
    (d, sets) <- getInstructions
    case d of
        DispatchRun -> run setup sets
        DispatchPreProcess -> runPreProcessor setup sets
        DispatchCheck -> runChecker setup sets
        DispatchInstall r -> install r sets

run :: ZiftSetup -> Settings -> IO ()
run ZiftSetup {..} =
    runWith $ \_ -> do
        runAsPreProcessor ziftPreprocessor
        runAsPreCheck ziftPreCheck
        runAsChecker ziftChecker

runPreProcessor :: ZiftSetup -> Settings -> IO ()
runPreProcessor ZiftSetup {..} =
    runWith $ \_ -> runAsPreProcessor ziftPreprocessor

runChecker :: ZiftSetup -> Settings -> IO ()
runChecker ZiftSetup {..} = runWith $ \_ -> runAsChecker ziftChecker

runWith :: (ZiftContext -> Zift ()) -> Settings -> IO ()
runWith func sets = do
    rd <- autoRootDir
    pchan <- newTChanIO
    fmvar <- newEmptyMVar
    let ctx =
            ZiftContext
            { rootdir = rd
            , settings = sets
            , printChan = pchan
            , recursionList = []
            }
    let runner =
            withSystemTempDir "zifter" $ \d ->
                withCurrentDir d $ do
                    (r, zs) <-
                        let zfunc = do
                                printZiftMessage
                                    ("CHANGED WORKING DIRECTORY TO " ++
                                     toFilePath d)
                                func ctx
                                printZiftMessage "ZIFTER DONE"
                        in zift zfunc ctx mempty
                    case r of
                        ZiftFailed err ->
                            atomically $
                            writeTChan pchan $
                            ZiftOutput [SetColor Foreground Dull Red] err
                        ZiftSuccess () -> pure ()
                    void $ tryFlushZiftBuffer ctx zs
                    putMVar fmvar ()
    let outputOne :: ZiftOutput -> IO ()
        outputOne (ZiftOutput commands str)
                -- when False $ do
         = do
            let color = setsOutputColor sets
            when color $ setSGR commands
            putStr str
            when color $ setSGR [Reset]
            putStr "\n" -- Because otherwise it doesn't work?
            hFlush stdout
                -- print str
    let outputAll = do
            mout <- atomically $ tryReadTChan pchan
            case mout of
                Nothing -> pure ()
                Just output -> do
                    outputOne output
                    outputAll
    let printer = do
            mdone <- tryTakeMVar fmvar
            case mdone of
                Just () -> outputAll
                Nothing -> do
                    output <- atomically $ readTChan pchan
                    outputOne output
                    printer
    printerAsync <- async printer
    runnerAsync <- async runner
    wait runnerAsync
    wait printerAsync

runAsPreProcessor :: Zift () -> Zift ()
runAsPreProcessor func = do
    printZiftMessage "PREPROCESSOR STARTING"
    func
    printZiftMessage "PREPROCESSOR DONE"

runAsPreCheck :: Zift () -> Zift ()
runAsPreCheck func = do
    printZiftMessage "PRECHECKER STARTING"
    func
    printZiftMessage "PRECHECKER DONE"

runAsChecker :: Zift () -> Zift ()
runAsChecker func = do
    printZiftMessage "CHECKER STARTING"
    func
    printZiftMessage "CHECKER DONE"

autoRootDir :: IO (Path Abs Dir)
autoRootDir = do
    pn <- getProgName
    here <- getCurrentDir
    (_, fs) <- listDir here
    unless (pn `elem` map (toFilePath . filename) fs) $
        die $
        unwords
            [ pn
            , "not found at"
            , toFilePath here
            , "the zift script must be run in the right directory."
            ]
    pure here

install :: Bool -> Settings -> IO ()
install recursive sets = do
    if recursive
        then flip runWith sets $ \_ ->
                 recursively $ \ziftFile -> liftIO $ installIn $ parent ziftFile
        else pure ()
    autoRootDir >>= installIn

installIn :: Path Abs Dir -> IO ()
installIn rootdir = do
    let gitdir = rootdir </> dotGitDir
    gd <- doesDirExist gitdir
    let gitfile = rootdir </> dotGitFile
    gf <- doesFileExist gitfile
    ghd <-
        case (gd, gf) of
            (True, True) -> die "The .git dir is both a file and a directory?"
            (False, False) ->
                die
                    "The .git dir is nor a file nor a directory, I don't know what to do."
            (True, False) -> pure $ gitdir </> hooksDir
            (False, True) -> do
                contents <- readFile $ toFilePath gitfile
                case splitAt (length "gitdir: ") contents of
                    ("gitdir: ", rest) ->
                        case initMay rest of
                            Just gitdirref -> do
                                sp <-
                                    D.canonicalizePath $
                                    toFilePath rootdir ++ gitdirref
                                let figureOutDoubleDots =
                                        FP.joinPath . go [] . FP.splitPath
                                      where
                                        go acc [] = reverse acc
                                        go (_:acc) ("../":xs) = go acc xs
                                        go acc (x:xs) = go (x : acc) xs
                                realgitdir <-
                                    parseAbsDir $ figureOutDoubleDots sp
                                pure $ realgitdir </> hooksDir
                            Nothing ->
                                die "no gitdir reference found in .git file."
                    _ ->
                        die
                            "Found weird contents of the .git file. It is a file but does not start with 'gitdir: '. I don't know what to do."
    let preComitFile = ghd </> $(mkRelFile "pre-commit")
    mc <- forgivingAbsence $ readFile $ toFilePath preComitFile
    let hookContents = "./zift.hs run\n"
    let justDoIt = do
            putStrLn $
                unwords
                    ["Installed pre-commit script in", toFilePath preComitFile]
            writeFile (toFilePath preComitFile) hookContents
            pcf <- D.getPermissions (toFilePath preComitFile)
            D.setPermissions (toFilePath preComitFile) $
                D.setOwnerExecutable True pcf
    case mc of
        Nothing -> justDoIt
        Just "" -> justDoIt
        Just c ->
            if c == hookContents
                then putStrLn "Hook already installed."
                else die $
                     unlines
                         [ "Not installing, a pre-commit hook already exists:"
                         , show c
                         ]

dotGitDir :: Path Rel Dir
dotGitDir = $(mkRelDir ".git")

dotGitFile :: Path Rel File
dotGitFile = $(mkRelFile ".git")

hooksDir :: Path Rel Dir
hooksDir = $(mkRelDir "hooks")