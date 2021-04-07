{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Language.TypeChecker where

import Data.List (intercalate)
import Debug.Trace (trace)
import Language.Pretty (pretty)
import Language.Syntax
  ( Argument (..),
    BinOp (..),
    Block (..),
    Expr (..),
    OptType (..),
    Stmt (..),
    Stmts,
    Type (..),
    UnaOp (..),
  )

-- ["int", "str", "print", "length", "make", "spawn", "send", "recv"]

type Env = [(String, OptType)]

data BoolWithError
  = Correct
  | Incorrect String String
  deriving (Eq)

expect :: OptType -> OptType -> BoolWithError
expect typ expected =
  if typ == expected
    then Correct
    else Incorrect (pretty expected) (pretty typ)

expectBoth :: BoolWithError -> BoolWithError -> BoolWithError
expectBoth x y =
  case x of
    Correct -> y
    Incorrect _ _ -> x

expectAll :: BoolWithError -> BoolWithError -> BoolWithError -> BoolWithError
expectAll x y z = expectBoth x (expectBoth y z)

prettyExprTypes :: [Expr] -> Env -> String
prettyExprTypes exprs env = intercalate ", " (map (\x -> pretty $ infer x env) exprs)

getEnv :: Stmts -> Env
getEnv =
  map
    ( \(FuncDef name args ftype _) ->
        (name, getFuncSignature args ftype)
    )

getFuncSignature :: [Argument] -> OptType -> OptType
getFuncSignature args return =
  Type
    ( FuncType
        (map (\(Arg _ argType) -> argType) args)
        return
    )

typeCheck :: Stmts -> Stmts
typeCheck stmts =
  let env = getEnv stmts
   in case check stmts NoType env of
        Correct -> stmts
        Incorrect exp msg ->
          error
            ( "Type error: Expected "
                ++ exp
                ++ ", got "
                ++ msg
            )

class TypeChecker t0 where
  infer :: t0 -> Env -> OptType
  check :: t0 -> OptType -> Env -> BoolWithError

instance TypeChecker Stmts where
  infer [] _ = NoType
  infer ((Return expr) : _) env = infer expr env
  infer ((Let name NoType expr) : rest) env =
    let exprType = infer expr env
     in case exprType of
          NoType -> error ("Type error: cannot assign nothing to \"" ++ name ++ "\"")
          _ -> infer rest ((name, exprType) : env)
  infer ((Let name exprType (App (Var "make") exprs)) : rest) env =
    if map (`infer` env) exprs == [Type IntType]
      then case exprType of
        NoType -> error ("Type error: \"make\" has no type annotation when assigning to \"" ++ name ++ "\"")
        (Type (ChannelType _)) -> infer rest ((name, exprType) : env)
      else error ("Type error: Invalid arguments given to \"make\" - " ++ prettyExprTypes exprs env)
  infer ((Let name exprType expr) : rest) env =
    case check expr exprType env of
      Correct -> infer rest ((name, exprType) : env)
      Incorrect exp msg ->
        error
          ( "Type error: Expected "
              ++ exp
              ++ ", got "
              ++ msg
          )
  infer ((Expr expr) : rest) env =
    infer expr env `seq` infer rest env
  infer ((FuncDef name args returnType block) : rest) env =
    let funcType = getFuncSignature args returnType
     in let env' = map (\(Arg argName argType) -> (argName, Type argType)) args ++ ((name, funcType) : env)
         in case check block returnType env' of
              Correct -> infer rest ((name, funcType) : env)
              Incorrect exp msg ->
                error
                  ( "Type error: Expected "
                      ++ exp
                      ++ ", got "
                      ++ msg
                  )
  infer ((If expr block) : rest) env =
    case check expr (Type BoolType) env of
      Correct ->
        let type' = infer rest env
         in case ( case block of
                     (Curly stmts) -> check (stmts ++ rest) type' env
                     (Inline expr) -> check (Expr expr : rest) type' env
                 ) of
              Correct -> type'
              Incorrect exp msg ->
                error
                  ( "Type error: Expected "
                      ++ exp
                      ++ ", got "
                      ++ msg
                  )
      Incorrect exp msg ->
        error
          ( "Type error: Expected "
              ++ exp
              ++ ", got "
              ++ msg
          )
  infer ((IfElse expr block1 block2) : rest) env =
    case check expr (Type BoolType) env of
      Correct ->
        let type' =
              ( case block1 of
                  (Curly stmts) -> infer (stmts ++ rest) env
                  (Inline expr) -> infer (Expr expr : rest) env
              )
         in case ( case block2 of
                     (Curly stmts) -> check (stmts ++ rest) type' env
                     (Inline expr) -> check (Expr expr : rest) type' env
                 ) of
              Correct -> type'
              Incorrect exp msg ->
                error
                  ( "Type error: Expected "
                      ++ exp
                      ++ ", got "
                      ++ msg
                  )
      Incorrect exp msg ->
        error
          ( "Type error: Expected "
              ++ exp
              ++ ", got "
              ++ msg
          )
  infer ((IfElseIf expr block stmt) : rest) env =
    case check expr (Type BoolType) env of
      Correct ->
        let type' =
              ( case block of
                  (Curly stmts) -> infer (stmts ++ rest) env
                  (Inline expr) -> infer (Expr expr : rest) env
              )
         in case check (stmt : rest) type' env of
              Correct -> type'
              Incorrect exp msg ->
                error
                  ( "Type error: Expected "
                      ++ exp
                      ++ ", got "
                      ++ msg
                  )
      Incorrect exp msg ->
        error
          ( "Type error: Expected "
              ++ exp
              ++ ", got "
              ++ msg
          )
  check (Return expr : _) expected env = expect (infer expr env) expected
  check stmts expected env = expect (infer stmts env) expected

instance TypeChecker Block where
  infer (Inline expr) env = infer expr env
  infer (Curly stmts) env = infer stmts env
  check (Inline expr) expected env = check expr expected env
  check (Curly stmts) expected env = check stmts expected env

instance TypeChecker Expr where
  check (Int _) expected _ = expect (Type IntType) expected
  check (String _) expected _ = expect (Type StringType) expected
  check (Boolean _) expected _ = expect (Type BoolType) expected
  check (Brack expr) expected env = check expr expected env
  check (UnaOp op expr) expected env =
    expectBoth
      (check op expected env)
      (check expr expected env)
  check (BinOp op expr1 expr2) expected env =
    let exprType = infer expr1 env
     in expectBoth
          (check op exprType env)
          (check expr2 exprType env)
  check (Var name) expected env = case lookup name env of
    (Just type') -> expect type' expected
    Nothing -> error ("Type error: \"" ++ name ++ "\" is undefined")
  check (App (Var "str") exprs) expected env =
    if length (map (`infer` env) exprs) == 1
      then expect (Type StringType) expected
      else error "Type error: Invalid number of arguments given to \"str\""
  check (App (Var "int") exprs) expected env =
    if length (map (`infer` env) exprs) == 1
      then expect (Type IntType) expected
      else error "Type error: Invalid number of arguments given to \"int\""
  check (App (Var "length") exprs) expected env =
    if map (`infer` env) exprs == [Type StringType]
      then expect (Type IntType) expected
      else error ("Type error: Invalid arguments given to \"length\" - " ++ prettyExprTypes exprs env)
  check (App (Var "print") exprs) expected env =
    if map (`infer` env) exprs == [Type StringType]
      then expect NoType expected
      else error ("Type error: Invalid arguments given to \"print\" - " ++ prettyExprTypes exprs env)
  check (App (Var "spawn") []) expected env = error "Type error: \"spawn\" must be given at least one argument"
  check (App (Var "spawn") (first : rest)) expected env =
    case infer first env of
      (Type (FuncType argTypes NoType)) ->
        if map (`infer` env) rest == map Type argTypes
          then expect NoType expected
          else error ("Type error: Invalid arguments given to \"spawn\" - " ++ prettyExprTypes (first : rest) env)
      _ -> error ("Type error: Invalid arguments given to \"spawn\" - " ++ prettyExprTypes (first : rest) env)
  check (App (Var "send") [first, second]) expected env =
    case infer first env of
      (Type (ChannelType chanType)) ->
        expectBoth
          (expect (infer second env) (Type chanType))
          (expect NoType expected)
      _ -> Incorrect "channel" (prettyExprTypes [first, second] env)
  check (App (Var "send") exprs) _ env = Incorrect "channel" (prettyExprTypes exprs env)
  check (App (Var "recv") exprs) expected env = case exprs of
    [chan] -> case infer chan env of
      (Type (ChannelType chanType)) ->
        expect (Type chanType) expected
      _ -> Incorrect "channel" (prettyExprTypes exprs env)
    _ -> Incorrect "channel" (prettyExprTypes exprs env)
  check (App (Var "make") _) _ _ = error "Type error: type annotation missing"
  check (App expr exprs) expected env =
    case infer expr env of
      (Type (FuncType argTypes returnType)) ->
        if map (`infer` env) exprs == map Type argTypes
          then expect returnType expected
          else error ("Type error: Invalid arguments given to \"" ++ pretty expr ++ "\" - " ++ intercalate ", " (map (\x -> pretty $ infer x env) exprs))
      _ -> error ("Type error: \"" ++ pretty expr ++ "\" is not a function")
  check (Assert (App (Var "make") exprs) type') expected env =
    if map (`infer` env) exprs == [Type IntType]
      then case type' of
        (ChannelType _) -> expect (Type type') expected
        _ -> Incorrect "channel" (pretty type')
      else Incorrect "int" (intercalate ", " (map (\x -> pretty $ infer x env) exprs))
  check (Assert expr type') expected env =
    expectBoth
      (check expr (Type type') env)
      (expect (Type type') expected)
  infer (Int _) _ = Type IntType
  infer (String _) _ = Type StringType
  infer (Boolean _) _ = Type BoolType
  infer (Brack expr) env = infer expr env
  infer (UnaOp op expr) env =
    let exprType = infer expr env
     in case check op exprType env of
          Correct -> exprType
          Incorrect exp msg ->
            error
              ( "Type error: Expected "
                  ++ exp
                  ++ ", got "
                  ++ msg
              )
  infer (BinOp op expr1 expr2) env =
    let exprType = infer expr1 env
     in case expectBoth (check op exprType env) (check expr2 exprType env) of
          Correct -> exprType
          Incorrect exp msg ->
            error
              ( "Type error: Expected "
                  ++ exp
                  ++ ", got "
                  ++ msg
              )
  infer (Var name) env = case lookup name env of
    (Just type') -> type'
    Nothing -> error ("Type error: \"" ++ name ++ "\" is undefined")
  infer (App (Var "str") exprs) env =
    if length (map (`infer` env) exprs) == 1
      then Type StringType
      else error "Type error: Invalid number of arguments given to \"str\""
  infer (App (Var "int") exprs) env =
    if length (map (`infer` env) exprs) == 1
      then Type IntType
      else error "Type error: Invalid number of arguments given to \"int\""
  infer (App (Var "length") exprs) env =
    if map (`infer` env) exprs == [Type StringType]
      then Type IntType
      else error ("Type error: Invalid arguments given to \"length\" - " ++ prettyExprTypes exprs env)
  infer (App (Var "print") exprs) env =
    if map (`infer` env) exprs == [Type StringType]
      then NoType
      else error ("Type error: Invalid arguments given to \"print\" - " ++ prettyExprTypes exprs env)
  infer (App (Var "spawn") exprs) env =
    case exprs of
      [] -> error "Type error: \"spawn\" must be given at least one argument"
      (first : rest) ->
        case infer first env of
          (Type (FuncType argTypes NoType)) ->
            if map (`infer` env) rest == map Type argTypes
              then NoType
              else error ("Type error: Invalid arguments given to \"spawn\" - " ++ prettyExprTypes exprs env)
          _ -> error ("Type error: Invalid arguments given to \"spawn\" - " ++ prettyExprTypes exprs env)
  infer (App (Var "send") exprs) env =
    case exprs of
      [first, second] -> case infer first env of
        (Type (ChannelType chanType)) ->
          if infer second env == Type chanType
            then NoType
            else error ("Type error: Invalid arguments given to \"send\" - " ++ prettyExprTypes exprs env)
      _ -> error ("Type error: Invalid arguments given to \"send\" - " ++ prettyExprTypes exprs env)
  infer (App (Var "recv") exprs) env =
    case exprs of
      [chan] -> case infer chan env of
        (Type (ChannelType chanType)) ->
          Type chanType
        _ -> error ("Type error: Invalid arguments given to \"recv\" - " ++ prettyExprTypes exprs env)
      _ -> error ("Type error: Invalid arguments given to \"recv\" - " ++ prettyExprTypes exprs env)
  infer (App (Var "make") exprs) env =
    error "Type error: type annotation missing"
  infer (App expr exprs) env =
    case infer expr env of
      (Type (FuncType argTypes returnType)) ->
        if map (`infer` env) exprs == map Type argTypes
          then returnType
          else error ("Type error: Invalid arguments given to \"" ++ pretty expr ++ "\" - " ++ prettyExprTypes exprs env)
      _ -> error ("Type error: \"" ++ pretty expr ++ "\" is not a function")
  infer (Assert (App (Var "make") exprs) type') env =
    if map (`infer` env) exprs == [Type IntType]
      then case type' of
        (ChannelType _) -> Type type'
        _ ->
          error
            ( "Type error: Expected "
                ++ "channel"
                ++ ", got "
                ++ pretty type'
            )
      else
        error
          ( "Type error: Expected ++"
              ++ "int"
              ++ ", got "
              ++ intercalate ", " (map (\x -> pretty $ infer x env) exprs)
          )
  infer (Assert expr type') env =
    case check expr (Type type') env of
      Correct -> Type type'
      Incorrect exp msg ->
        error
          ( "Type error: Expected "
              ++ exp
              ++ ", got "
              ++ msg
          )

instance TypeChecker UnaOp where
  infer Inv _ = Type BoolType
  check Inv expected _ = expect (Type BoolType) expected

instance TypeChecker BinOp where
  infer Equals _ = error "Cannot infer type of Equals operator"
  infer NotEquals _ = error "Cannot infer type of NotEquals operator"
  infer Or _ = Type BoolType
  infer And _ = Type BoolType
  infer Plus _ = Type IntType
  infer Minus _ = Type IntType
  infer Div _ = Type IntType
  infer Times _ = Type IntType
  infer GreaterThan _ = Type IntType
  infer LessThan _ = Type IntType
  infer GreaterEq _ = Type IntType
  infer LessEq _ = Type IntType
  infer Concat _ = Type StringType
  check Equals expected _ =
    if expected `elem` [Type BoolType, Type StringType, Type IntType]
      then Correct
      else Incorrect (pretty expected) "bool, string, int"
  check NotEquals expected _ =
    if expected `elem` [Type BoolType, Type StringType, Type IntType]
      then Correct
      else Incorrect (pretty expected) "bool, string, int"
  check Or (Type BoolType) _ = Correct
  check And (Type BoolType) _ = Correct
  check Plus (Type IntType) _ = Correct
  check Minus (Type IntType) _ = Correct
  check Div (Type IntType) _ = Correct
  check Times (Type IntType) _ = Correct
  check GreaterThan (Type IntType) _ = Correct
  check LessThan (Type IntType) _ = Correct
  check GreaterEq (Type IntType) _ = Correct
  check LessEq (Type IntType) _ = Correct
  check Concat (Type StringType) _ = Correct
  check op expected _ = Incorrect (pretty expected) (pretty (infer op []))
