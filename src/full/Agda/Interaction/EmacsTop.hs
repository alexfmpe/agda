module Agda.Interaction.EmacsTop
    ( mimicGHCi
    , namedMetaOf
    , showGoals
    , showInfoError
    , explainWhyInScope
    , prettyTypeOfMeta
    , prettySubTypeOfMeta
    ) where

import Control.Monad
import Control.Monad.IO.Class ( MonadIO(..) )
import Control.Monad.State    ( evalStateT )
import Control.Monad.Trans    ( lift )

import qualified Data.List as List

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.Syntax.Abstract.Pretty (prettyATop)
import Agda.Syntax.Abstract as A
import Agda.Syntax.Concrete as C

import Agda.TypeChecking.Errors ( explainWhyInScope, getAllWarningsOfTCErr, prettyError )
import qualified Agda.TypeChecking.Pretty as TCP
import Agda.TypeChecking.Pretty (prettyTCM)
import Agda.TypeChecking.Pretty.Warning (prettyTCWarnings, prettyTCWarnings')
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Warnings (WarningsAndNonFatalErrors(..))
import Agda.Interaction.AgdaTop
import Agda.Interaction.Base
import Agda.Interaction.BasicOps as B
import Agda.Interaction.Response as R
import Agda.Interaction.EmacsCommand hiding (putResponse)
import Agda.Interaction.Highlighting.Emacs
import Agda.Interaction.Highlighting.Precise (TokenBased(..))
import Agda.Interaction.InteractionTop (localStateCommandM)
import Agda.Utils.Function (applyWhen)
import Agda.Utils.Null (empty)
import Agda.Utils.Maybe
import Agda.Utils.Pretty
import Agda.Utils.String
import Agda.Utils.Time (CPUTime)
import Agda.VersionCommit
import Agda.TypeChecking.Monad.Boundary

----------------------------------

-- | 'mimicGHCi' is a fake ghci interpreter for the Emacs frontend
--   and for interaction tests.
--
--   'mimicGHCi' reads the Emacs frontend commands from stdin,
--   interprets them and print the result into stdout.
mimicGHCi :: TCM () -> TCM ()
mimicGHCi = repl (liftIO . mapM_ (putStrLn . prettyShow) <=< lispifyResponse) "Agda2> "

-- | Convert Response to an elisp value for the interactive emacs frontend.

lispifyResponse :: Response -> TCM [Lisp String]
lispifyResponse (Resp_HighlightingInfo info remove method modFile) =
  (:[]) <$> liftIO (lispifyHighlightingInfo info remove method modFile)
lispifyResponse (Resp_DisplayInfo info) = lispifyDisplayInfo info
lispifyResponse (Resp_ClearHighlighting tokenBased) =
  return [ L $ A "agda2-highlight-clear" :
               case tokenBased of
                 NotOnlyTokenBased -> []
                 TokenBased        ->
                   [ Q (lispifyTokenBased tokenBased) ]
         ]
lispifyResponse Resp_DoneAborting = return [ L [ A "agda2-abort-done" ] ]
lispifyResponse Resp_DoneExiting  = return [ L [ A "agda2-exit-done"  ] ]
lispifyResponse Resp_ClearRunningInfo = return [ clearRunningInfo ]
lispifyResponse (Resp_RunningInfo n s)
  | n <= 1    = return [ displayRunningInfo s ]
  | otherwise = return [ L [A "agda2-verbose", A (quote s)] ]
lispifyResponse (Resp_Status s)
    = return [ L [ A "agda2-status-action"
                 , A (quote $ List.intercalate "," $ catMaybes [checked, showImpl, showIrr])
                 ]
             ]
  where
    checked  = boolToMaybe (sChecked                 s) "Checked"
    showImpl = boolToMaybe (sShowImplicitArguments   s) "ShowImplicit"
    showIrr  = boolToMaybe (sShowIrrelevantArguments s) "ShowIrrelevant"

lispifyResponse (Resp_JumpToError f p) = return
  [ lastTag 3 $
      L [ A "agda2-maybe-goto", Q $ L [A (quote f), A ".", A (show p)] ]
  ]
lispifyResponse (Resp_InteractionPoints is) = return
  [ lastTag 1 $
      L [A "agda2-goals-action", Q $ L $ map showNumIId is]
  ]
lispifyResponse (Resp_GiveAction ii s)
    = return [ L [ A "agda2-give-action", showNumIId ii, A s' ] ]
  where
    s' = case s of
        Give_String str -> quote str
        Give_Paren      -> "'paren"
        Give_NoParen    -> "'no-paren"
lispifyResponse (Resp_MakeCase ii variant pcs) = return
  [ lastTag 2 $ L [ A cmd, Q $ L $ map (A . quote) pcs ] ]
  where
  cmd = case variant of
    R.Function       -> "agda2-make-case-action"
    R.ExtendedLambda -> "agda2-make-case-action-extendlam"
lispifyResponse (Resp_SolveAll ps) = return
  [ lastTag 2 $
      L [ A "agda2-solveAll-action", Q . L $ concatMap prn ps ]
  ]
  where
    prn (ii,e)= [showNumIId ii, A $ quote $ prettyShow e]

lispifyDisplayInfo :: DisplayInfo -> TCM [Lisp String]
lispifyDisplayInfo info = case info of
    Info_CompilationOk backend ws -> do
      warnings <- prettyTCWarnings (tcWarnings ws)
      errors <- prettyTCWarnings (nonFatalErrors ws)
      let
        msg = concat
          [ "The module was successfully compiled with backend "
          , prettyShow backend
          , ".\n"
          ]
      -- abusing the goals field since we ignore the title
        (body, _) = formatWarningsAndErrors msg warnings errors
      format body "*Compilation result*"
    Info_Constraints s -> do
      doc <- TCP.vcat $ map prettyTCM s
      format (render doc) "*Constraints*"
    Info_AllGoalsWarnings ms ws -> do
      goals <- showGoals ms
      warnings <- prettyTCWarnings (tcWarnings ws)
      errors <- prettyTCWarnings (nonFatalErrors ws)
      let (body, title) = formatWarningsAndErrors goals warnings errors
      format body ("*All" ++ title ++ "*")
    Info_Auto s -> format s "*Auto*"
    Info_Error err -> do
      s <- showInfoError err
      format s "*Error*"
    Info_Time s -> format (render $ prettyTimed s) "*Time*"
    Info_NormalForm state cmode time expr -> do
      exprDoc <- evalStateT prettyExpr state
      let doc = maybe empty prettyTimed time $$ exprDoc
          lbl | cmode == HeadCompute = "*Head Normal Form*"
              | otherwise            = "*Normal Form*"
      format (render doc) lbl
      where
        prettyExpr = localStateCommandM
            $ lift
            $ B.atTopLevel
            $ allowNonTerminatingReductions
            $ (if computeIgnoreAbstract cmode then ignoreAbstractMode else inConcreteMode)
            $ (B.showComputed cmode)
            $ expr
    Info_InferredType state time expr -> do
      exprDoc <- evalStateT prettyExpr state
      let doc = maybe empty prettyTimed time $$ exprDoc
      format (render doc) "*Inferred Type*"
      where
        prettyExpr = localStateCommandM
            $ lift
            $ B.atTopLevel
            $ TCP.prettyA
            $ expr
    Info_ModuleContents modules tel types -> do
      doc <- localTCState $ do
        typeDocs <- addContext tel $ forM types $ \ (x, t) -> do
          doc <- prettyTCM t
          return (prettyShow x, ":" <+> doc)
        return $ vcat
          [ "Modules"
          , nest 2 $ vcat $ map pretty modules
          , "Names"
          , nest 2 $ align 10 typeDocs
          ]
      format (render doc) "*Module contents*"
    Info_SearchAbout hits names -> do
      hitDocs <- forM hits $ \ (x, t) -> do
        doc <- prettyTCM t
        return (prettyShow x, ":" <+> doc)
      let doc = "Definitions about" <+>
                text (List.intercalate ", " $ words names) $$ nest 2 (align 10 hitDocs)
      format (render doc) "*Search About*"
    Info_WhyInScope why -> do
      doc <- explainWhyInScope why
      format (render doc) "*Scope Info*"
    Info_Context ii ctx -> do
      doc <- localTCState (prettyResponseContext ii False ctx)
      format (render doc) "*Context*"
    Info_Intro_NotFound -> format "No introduction forms found." "*Intro*"
    Info_Intro_ConstructorUnknown ss -> do
      let doc = sep [ "Don't know which constructor to introduce of"
                    , let mkOr []     = []
                          mkOr [x, y] = [text x <+> "or" <+> text y]
                          mkOr (x:xs) = text x : mkOr xs
                      in nest 2 $ fsep $ punctuate comma (mkOr ss)
                    ]
      format (render doc) "*Intro*"
    Info_Version -> format ("Agda version " ++ versionWithCommitInfo) "*Agda Version*"
    Info_GoalSpecific ii kind -> lispifyGoalSpecificDisplayInfo ii kind

lispifyGoalSpecificDisplayInfo :: InteractionId -> GoalDisplayInfo -> TCM [Lisp String]
lispifyGoalSpecificDisplayInfo ii kind = localTCState $ withInteractionId ii $
  case kind of
    Goal_HelperFunction helperType -> do
      doc <- inTopContext $ prettyATop helperType
      return [ L [ A "agda2-info-action-and-copy"
                 , A $ quote "*Helper function*"
                 , A $ quote (render doc ++ "\n")
                 , A "nil"
                 ]
             ]
    Goal_NormalForm cmode expr -> do
      doc <- showComputed cmode expr
      format (render doc) "*Normal Form*"   -- show?
    Goal_ExtensionType norm -> do
      doc <- inTopContext $ prettySubTypeOfMeta norm ii
      return [ L [ A "agda2-info-action-and-copy"
                 , A $ quote "*Goal boundary as subtype*"
                 , A $ quote (render doc ++ "\n")
                 , A "nil"
                 ]
             ]

    Goal_GoalType norm aux ctx boundary constraints -> do
      ctxDoc <- prettyResponseContext ii True ctx
      goalDoc <- prettyTypeOfMeta norm ii
      auxDoc <- case aux of
            GoalOnly -> return empty
            GoalAndHave expr -> do
              doc <- prettyATop expr
              return $ "Have:" <+> doc
            GoalAndElaboration term -> do
              doc <- TCP.prettyTCM term
              return $ "Elaborates to:" <+> doc
      let boundaryDoc
            | null (boundaryFaces boundary) = []
            | otherwise  = [ text $ delimiter "Boundary"
                           , vcat $ map pretty (boundaryFaces boundary)
                           ]
      let constraintsDoc
            | null constraints = []
            | otherwise        =
              [ TCP.text $ delimiter "Constraints"
              , TCP.vcat $ map prettyTCM constraints
              ]
      doc <- TCP.vcat $
        [ "Goal:" TCP.<+> return goalDoc
        , return auxDoc
        , return (vcat boundaryDoc)
        , TCP.text (replicate 60 '\x2014')
        , return ctxDoc
        ] ++ constraintsDoc
      format (render doc) "*Goal type etc.*"
    Goal_CurrentGoal norm -> do
      doc <- prettyTypeOfMeta norm ii
      format (render doc) "*Current Goal*"
    Goal_InferredType expr -> do
      doc <- prettyATop expr
      format (render doc) "*Inferred Type*"

-- | Format responses of DisplayInfo

format :: String -> String -> TCM [Lisp String]
format content bufname = return [ display_info' False bufname content ]

-- | Adds a \"last\" tag to a response.

lastTag :: Integer -> Lisp String -> Lisp String
lastTag n r = Cons (Cons (A "last") (A $ show n)) r

-- | Show an iteraction point identifier as an elisp expression.

showNumIId :: InteractionId -> Lisp String
showNumIId = A . show . interactionId

--------------------------------------------------------------------------------

-- | Given strings of goals, warnings and errors, return a pair of the
--   body and the title for the info buffer
formatWarningsAndErrors :: String -> String -> String -> (String, String)
formatWarningsAndErrors g w e = (body, title)
  where
    isG = not $ null g
    isW = not $ null w
    isE = not $ null e
    title = List.intercalate "," $ catMaybes
              [ " Goals"    <$ guard isG
              , " Errors"   <$ guard isE
              , " Warnings" <$ guard isW
              , " Done"     <$ guard (not (isG || isW || isE))
              ]

    body = List.intercalate "\n" $ catMaybes
             [ g                    <$ guard isG
             , delimiter "Errors"   <$ guard (isE && (isG || isW))
             , e                    <$ guard isE
             , delimiter "Warnings" <$ guard (isW && (isG || isE))
             , w                    <$ guard isW
             ]


-- | Serializing Info_Error
showInfoError :: Info_Error -> TCM String
showInfoError (Info_GenericError err) = do
  e <- prettyError err
  w <- prettyTCWarnings' =<< getAllWarningsOfTCErr err

  let errorMsg  = if null w
                      then e
                      else delimiter "Error" ++ "\n" ++ e
  let warningMsg = List.intercalate "\n" $ delimiter "Warning(s)"
                                      : filter (not . null) w
  return $ if null w
            then errorMsg
            else errorMsg ++ "\n\n" ++ warningMsg
showInfoError (Info_CompilationError warnings) = do
  s <- prettyTCWarnings warnings
  return $ unlines
            [ "You need to fix the following errors before you can compile"
            , "the module:"
            , ""
            , s
            ]
showInfoError (Info_HighlightingParseError ii) =
  return $ "Highlighting failed to parse expression in " ++ show ii
showInfoError (Info_HighlightingScopeCheckError ii) =
  return $ "Highlighting failed to scope check expression in " ++ show ii

-- | Pretty-prints the context of the given meta-variable.

prettyResponseContext
  :: InteractionId  -- ^ Context of this meta-variable.
  -> Bool           -- ^ Print the elements in reverse order?
  -> [ResponseContextEntry]
  -> TCM Doc
prettyResponseContext ii rev ctx = withInteractionId ii $ do
  mod   <- asksTC getModality
  align 10 . concat . applyWhen rev reverse <$> do
    forM ctx $ \ (ResponseContextEntry n x (Arg ai expr) letv nis) -> do
      let
        prettyCtxName :: String
        prettyCtxName
          | n == x                 = prettyShow x
          | isInScope n == InScope = prettyShow n ++ " = " ++ prettyShow x
          | otherwise              = prettyShow x

        -- Some attributes are useful to report whenever they are not
        -- in the default state.
        attribute :: String
        attribute = c ++ if null c then "" else " "
          where c = prettyShow (getCohesion ai)

        extras :: [Doc]
        extras = concat $
          [ [ "not in scope" | isInScope nis == C.NotInScope ]
            -- Print erased if hypothesis is erased by goal is non-erased.
          , [ "erased"       | not $ getQuantity  ai `moreQuantity` getQuantity  mod ]
            -- Print irrelevant if hypothesis is strictly less relevant than goal.
          , [ "irrelevant"   | not $ getRelevance ai `moreRelevant` getRelevance mod ]
            -- Print instance if variable is considered by instance search
          , [ "instance"     | isInstance ai ]
          ]
      ty <- prettyATop expr
      maybeVal <- traverse prettyATop letv

      return $
        (attribute ++ prettyCtxName, ":" <+> ty <+> (parenSep extras)) :
        [ (prettyShow x, "=" <+> val) | val <- maybeToList maybeVal ]

  where
    parenSep :: [Doc] -> Doc
    parenSep docs
      | null docs = empty
      | otherwise = (" " <+>) $ parens $ fsep $ punctuate comma docs


-- | Pretty-prints the type of the meta-variable.

prettyTypeOfMeta :: Rewrite -> InteractionId -> TCM Doc
prettyTypeOfMeta norm ii = do
  form <- B.typeOfMeta norm ii
  case form of
    OfType _ e -> prettyATop e
    _          -> prettyATop form

prettySubTypeOfMeta :: Rewrite -> InteractionId -> TCM Doc
prettySubTypeOfMeta norm ii = do
  form <- B.subTypeOfMeta norm ii
  case form of
    OfType _ e -> prettyATop e
    _          -> prettyATop form

-- | Prefix prettified CPUTime with "Time:"
prettyTimed :: CPUTime -> Doc
prettyTimed time = "Time:" <+> pretty time
