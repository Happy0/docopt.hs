module System.Console.Docopt.UsageParse 
  where

import           Data.Map (Map)
import qualified Data.Map as M
import           Data.List (nub)

import System.Console.Docopt.ParseUtils
import System.Console.Docopt.Types

-- * Helpers

-- | Flattens the top level of a Pattern, as long as that 
--   /does not/ alter the matching semantics of the Pattern
flatten :: Pattern a -> Pattern a
flatten (Sequence (x:[])) = x
flatten (OneOf (x:[]))    = x
flatten x                 = x

flatSequence = flatten . Sequence
flatOneOf = flatten . OneOf


-- * Pattern Parsers 

pLine :: CharParser u OptPattern
pLine = flatten . OneOf <$> pExpSeq `sepBy1` (inlineSpaces >> pipe)

pExpSeq :: CharParser u OptPattern
pExpSeq = flatten . Sequence <$> (pExp `sepEndBy1` inlineSpaces1)

pOptGroup :: CharParser u [OptPattern]
pOptGroup = pGroup '[' pExpSeq ']'

pReqGroup :: CharParser u [OptPattern]
pReqGroup = pGroup '(' pExpSeq ')'

pShortOption :: CharParser u (Char, Bool)
pShortOption = try $ do char '-' 
                        ch <- letter 
                        expectsVal <- option False pOptionArgument
                        return (ch, expectsVal)

pStackedShortOption :: CharParser u OptPattern
pStackedShortOption = try $ do 
    char '-'
    chars <- many letter
    case length chars of
      0 -> fail ""
      1 -> return $ Atom . ShortOption $ head chars
      _ -> return $ Repeated . OneOf $ map (Atom . ShortOption) chars

pLongOption :: CharParser u (Name, Bool)
pLongOption = try $ do string "--" 
                       name <- many1 $ oneOf alphanumerics
                       expectsVal <- option False pOptionArgument
                       return (name, expectsVal)

pAnyOption :: CharParser u String
pAnyOption = try (string "options")

pOptionArgument :: CharParser u Bool -- True if one is encountered, else False
pOptionArgument = try $ do char '=' <|> inlineSpace
                           pArgument <|> many1 (oneOf uppers)
                           return True
                  <|> return False

pArgument :: CharParser u String
pArgument = between (char '<') (char '>') pCommand

pCommand :: CharParser u String
pCommand = many1 (oneOf alphanumerics)

-- '<arg>...' make an OptPattern Repeated if followed by ellipsis
repeatable :: CharParser u OptPattern -> CharParser u OptPattern
repeatable p = do 
    expct <- p
    tryRepeat <- ((try ellipsis) >> (return Repeated)) <|> (return id)
    return (tryRepeat expct)

pExp :: CharParser u OptPattern
pExp = inlineSpaces >> repeatable value
     where value = Optional . flatOneOf <$> pOptGroup
               <|> flatOneOf <$> pReqGroup
               <|> pStackedShortOption
               <|> Atom . LongOption . fst <$> pLongOption
               <|> return (Repeated $ Atom AnyOption) <* pAnyOption
               <|> Atom . Argument <$> pArgument
               <|> Atom . Command <$> pCommand


-- * Usage Pattern Parsers

pUsageHeader :: CharParser u String
pUsageHeader = try $ do 
    u <- (char 'U' <|> char 'u')
    sage <- string "sage:"
    return (u:sage)

-- | Ignores leading spaces and first word, then parses
--   the rest of the usage line
pUsageLine :: CharParser u OptPattern
pUsageLine = 
    try $ do
        inlineSpaces 
        many1 (satisfy (not . isSpace)) -- prog name
        pLine

pUsagePatterns :: CharParser u OptPattern
pUsagePatterns = do
        many (notFollowedBy pUsageHeader >> anyChar)
        pUsageHeader
        optionalEndline
        usageLines <- (pUsageLine `sepEndBy` endline)
        return $ flatten . OneOf $ usageLines

-- * Option Synonyms & Defaults Parsers

-- | Succeeds only on the first line of an option explanation
--   (one whose first non-space character is '-')
begOptionLine :: CharParser u String
begOptionLine = inlineSpaces >> lookAhead (char '-') >> return "-"

pOptSynonyms :: CharParser u ([Option], Bool)
pOptSynonyms = do inlineSpaces 
                  pairs <- p `sepEndBy1` (optional (char ',') >> inlineSpace)
                  let expectations = map fst pairs
                      expectsVal = or $ map snd pairs
                  return (expectations, expectsVal)
             where p =   (\(c, ev) -> (ShortOption c, ev)) <$> pShortOption
                     <|> (\(s, ev) -> (LongOption s, ev)) <$> pLongOption

pDefaultTag :: CharParser u String
pDefaultTag = 
  let caseInsensitive = sequence_ . (map (\c -> (char $ toLower c) <|> (char $ toUpper c)))
  in do
    caseInsensitive "[default:"
    inlineSpaces
    def <- many (noneOf "]")
    char ']'
    return def

pOptDefault :: CharParser u (Maybe String)
pOptDefault = do
    skipUntil (pDefaultTag <|> (newline >> begOptionLine))
    maybeDefault <- optionMaybe pDefaultTag
    return maybeDefault

pOptDescription :: CharParser OptInfoMap ()
pOptDescription = try $ do
    (syns, expectsVal) <- pOptSynonyms
    def <- pOptDefault
    skipUntil (newline >> begOptionLine)
    updateState $ \infomap -> 
      let optinfo = (fromSynList syns) {defaultVal = def, expectsVal = expectsVal}
          saveOptInfo mp expct = M.insert expct optinfo mp
      in  foldl saveOptInfo infomap syns 
    return ()

pOptDescriptions :: CharParser OptInfoMap OptInfoMap
pOptDescriptions = do
    skipUntil (newline >> begOptionLine)
    optional newline
    setState M.empty
    optional $ pOptDescription `sepEndBy` endline
    getState


-- | Main usage parser: parses all of the usage lines into an Exception,
--   and all of the option descriptions along with any accompanying 
--   defaults, and returns both in a tuple
pDocopt :: CharParser OptInfoMap OptFormat
pDocopt = do
    optPattern <- pUsagePatterns
    optInfoMap <- pOptDescriptions
    let optPattern' = expectSynonyms optInfoMap optPattern
        saveCanRepeat pat el minfo = case minfo of 
          (Just info) -> Just $ info {isRepeated = canRepeat pat el}
          (Nothing)   -> Just $ (fromSynList []) {isRepeated = canRepeat pat el}
        optInfoMap' = alterAllWithKey (saveCanRepeat optPattern') (atoms optPattern') optInfoMap
    return (optPattern', optInfoMap')


-- ** Pattern transformation & analysis

expectSynonyms :: OptInfoMap -> OptPattern -> OptPattern
expectSynonyms oim (Sequence exs) = Sequence $ map (expectSynonyms oim) exs
expectSynonyms oim (OneOf exs)    = OneOf $ map (expectSynonyms oim) exs
expectSynonyms oim (Optional ex)  = Optional $ expectSynonyms oim ex
expectSynonyms oim (Repeated ex)  = Repeated $ expectSynonyms oim ex
expectSynonyms oim a@(Atom atom)  = case atom of
    e@(Command ex)    -> a
    e@(Argument ex)   -> a
    e@(AnyOption)     -> a
    e@(LongOption ex)  -> 
        case synonyms <$> e `M.lookup` oim of
          Just syns -> OneOf $ map Atom syns
          Nothing -> a
    e@(ShortOption c) -> 
        case synonyms <$> e `M.lookup` oim of
          Just syns -> OneOf $ map Atom syns
          Nothing -> a

canRepeat :: Eq a => Pattern a -> a -> Bool
canRepeat pat target = 
  case pat of
    (Sequence ps) -> canRepeatInside || (atomicOccurrences > 1)
        where canRepeatInside = foldl (||) False $ map ((flip canRepeat) target) ps      
              atomicOccurrences = length $ filter (== target) $ atoms $ Sequence ps
    (OneOf ps) -> foldl (||) False $ map ((flip canRepeat) target) ps
    (Optional p) -> canRepeat p target
    (Repeated p) -> target `elem` (atoms pat)
    (Atom a) -> False

