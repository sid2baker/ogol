defmodule Ogol.Sequence.Expr do
  @moduledoc """
  Helpers for building typed expressions in Sequence DSL source.
  """

  alias Ogol.Sequence.Model

  @spec not_expr(term()) :: struct()
  def not_expr(expr), do: %Model.Expr.Not{expr: expr}

  @spec and_expr(term(), term()) :: struct()
  def and_expr(left, right), do: %Model.Expr.And{left: left, right: right}

  @spec or_expr(term(), term()) :: struct()
  def or_expr(left, right), do: %Model.Expr.Or{left: left, right: right}

  @spec eq(term(), term()) :: struct()
  def eq(left, right), do: %Model.Expr.Compare{op: :==, left: left, right: right}

  @spec neq(term(), term()) :: struct()
  def neq(left, right), do: %Model.Expr.Compare{op: :!=, left: left, right: right}

  @spec lt(term(), term()) :: struct()
  def lt(left, right), do: %Model.Expr.Compare{op: :<, left: left, right: right}

  @spec lte(term(), term()) :: struct()
  def lte(left, right), do: %Model.Expr.Compare{op: :<=, left: left, right: right}

  @spec gt(term(), term()) :: struct()
  def gt(left, right), do: %Model.Expr.Compare{op: :>, left: left, right: right}

  @spec gte(term(), term()) :: struct()
  def gte(left, right), do: %Model.Expr.Compare{op: :>=, left: left, right: right}
end
