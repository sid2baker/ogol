<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- spark-start -->
## spark usage
_Generic tooling for building DSLs_

# Rules for working with Spark

## Overview

Spark is a framework for building Domain-Specific Languages (DSLs) in Elixir. It enables developers to create declarative DSLs with minimal boilerplate.

## Core Architecture

### 1. Entity-Section-Extension Model

Spark DSLs are built using three core components:

```elixir
# 1. Entities - Individual DSL constructors
@field %Spark.Dsl.Entity{
  name: :field,                    # DSL function name
  target: MyApp.Field,            # Struct to build
  args: [:name, :type],           # Positional arguments
  schema: [                       # Validation schema
    name: [type: :atom, required: true],
    type: [type: :atom, required: true]
  ]
}

# 2. Sections - Organize related entities
@fields %Spark.Dsl.Section{
  name: :fields,
  entities: [@field],             # Contains entities
  sections: [],                   # Can nest sections
  schema: [                       # Section-level options
    required: [type: {:list, :atom}, default: []]
  ]
}

# 3. Extensions - Package DSL functionality
defmodule MyExtension do
  use Spark.Dsl.Extension,
    sections: [@fields],
    transformers: [MyTransformer],
    verifiers: [MyVerifier]
end
```

### 2. Compile-Time Processing Pipeline

```
DSL Definition → Parsing → Validation → Transformation → Verification → Code Generation
```

1. **Parsing**: DSL syntax converted to internal representation
2. **Validation**: Schema validation via `Spark.Options`
3. **Transformation**: Transformers modify DSL state
4. **Verification**: Verifiers validate final state
5. **Code Generation**: Generate runtime modules/functions

## Creating a DSL with Spark

### Basic DSL Structure

```elixir
# Step 1: Define your extension
defmodule MyLibrary.Dsl do
  @my_nested_entity %Spark.Dsl.Entity{
    name: :my_nested_entity,
    target: MyLibrary.MyNestedEntity,
    describe: """
    Describe the entity.
    """,
    examples: [
      "my_nested_entity :name, option: \"something\"",
      """
      my_nested_entity :name do
        option "something"
      end
      """
    ],
    args: [:name],
    schema: [
      name: [type: :atom, required: true, doc: "The name of the entity"],
      option: [type: :string, default: "default", doc: "An option that does X"]
    ]
  }

  @my_entity %Spark.Dsl.Entity{
    name: :my_entity,
    target: MyLibrary.MyEntity,
    args: [:name],
    entities: [
      entities: [@my_nested_entity]
    ],
   describe: ...,
    examples: [...],
    schema: [
      name: [type: :atom, required: true, doc: "The name of the entity"],
      option: [type: :string, default: "default", doc: "An option that does X"]
    ]
  }
  
  @my_section %Spark.Dsl.Section{
    name: :my_section,
    describe: ...,
    examples: [...],
    schema: [
      section_option: [type: :string]
    ],
    entities: [@my_entity]
  }
  
  use Spark.Dsl.Extension, sections: [@my_section]
end

# Entity Targets
defmodule MyLibrary.MyEntity do
  defstruct [:name, :option, :entities, :__spark_metadata__]
end

defmodule MyLibrary.MyNestedEntity do
  defstruct [:name, :option, :__spark_metadata__]
end

# Step 2: Create the DSL module
defmodule MyLibrary do
  use Spark.Dsl, 
    default_extensions: [
      extensions: [MyLibrary.Dsl]
    ]
end

# Step 3: Use the DSL
defmodule MyApp.Example do
  use MyLibrary
  
  my_section do
    my_entity :example_name do
      option "custom value"
      my_nested_entity :nested_name do
        option "nested custom value"
      end
    end
  end
end
```

### Working with Transformers

Transformers modify the DSL at compile time:

```elixir
defmodule MyLibrary.Transformers.AddDefaults do
  use Spark.Dsl.Transformer
  
  def transform(dsl_state) do
    # Add a default entity if none exist
    entities = Spark.Dsl.Extension.get_entities(dsl_state, [:my_section])
    
    if Enum.empty?(entities) do
      {:ok, 
       Spark.Dsl.Transformer.add_entity(
         dsl_state,
         [:my_section],
         %MyLibrary.MyEntity{name: :default}
       )}
    else
      {:ok, dsl_state}
    end
  end
  
  # Control execution order
  def after?(_), do: false
  def before?(OtherTransformer), do: true
  def before?(_), do: false
end
```

### Creating Verifiers

Verifiers validate the final DSL state:

```elixir
defmodule MyLibrary.Verifiers.UniqueNames do
  use Spark.Dsl.Verifier

  def verify(dsl_state) do
    entities = Spark.Dsl.Extension.get_entities(dsl_state, [:my_section])
    names = Enum.map(entities, & &1.name)

    if length(names) == length(Enum.uniq(names)) do
      :ok
    else
      # Find the duplicate entity to get its location
      duplicate_name =
        names
        |> Enum.frequencies()
        |> Enum.find_value(fn {name, count} -> if count > 1, do: name end)

      duplicate_entity = Enum.find(entities, &(&1.name == duplicate_name))
      location = Spark.Dsl.Entity.anno(duplicate_entity)

      {:error,
       Spark.Error.DslError.exception(
         message: "Entity names must be unique, found duplicate: #{duplicate_name}",
         path: [:my_section, duplicate_name],
         module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
         location: location
       )}
    end
  end
end
```

## Info Modules

Spark provides an Info Generator system for introspection of DSL-defined modules. All introspection should go through info modules rather than accessing DSL state directly.

### 1. Info Module Generation
```elixir
# Define an info module for your extension
defmodule MyLibrary.Info do
  use Spark.InfoGenerator,
    extension: MyLibrary.Dsl,
    sections: [:my_section]
end

# The info generator creates accessor functions for DSL data:
# - MyLibrary.Info.my_section_entities(module)
# - MyLibrary.Info.my_section_option!(module, :option_name)
# - MyLibrary.Info.my_section_option(module, :option_name, default)

# Example usage:
entities = MyLibrary.Info.my_section_entities(MyApp.Example)
required_option = MyLibrary.Info.my_section_option!(MyApp.Example, :required)
{:ok,optional_value} = MyLibrary.Info.my_section_option(MyApp.Example, :optional, "default")

```

Benefits of using info modules:
- **Type Safety**: Generated functions provide compile-time guarantees
- **Performance**: Info data is cached and optimized for runtime access
- **Consistency**: Standardized API across all Spark-based libraries
- **Documentation**: Auto-generated docs for introspection functions

## Key APIs for Development

### Essential Functions

```elixir
# Get entities from a section
entities = Spark.Dsl.Extension.get_entities(dsl_state, [:section_path])

# Get section options
option = Spark.Dsl.Extension.get_opt(dsl_state, [:section_path], :option_name, default_value)

# Add entities during transformation
dsl_state = Spark.Dsl.Transformer.add_entity(dsl_state, [:section_path], entity)

# Persist data across transformers
dsl_state = Spark.Dsl.Transformer.persist(dsl_state, :key, value)
value = Spark.Dsl.Transformer.get_persisted(dsl_state, :key)

# Get current module being compiled
module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

# Get annotation information for error reporting
section_anno = Spark.Dsl.Transformer.get_section_anno(dsl_state, [:section_path])
option_anno = Spark.Dsl.Transformer.get_opt_anno(dsl_state, [:section_path], :option_name)
entity_anno = Spark.Dsl.Entity.anno(entity)
```

### Schema Definition with Spark.Options

```elixir
schema = [
  required_field: [
    type: :atom,
    required: true,
    doc: "Documentation for the field"
  ],
  optional_field: [
    type: {:list, :string},
    default: [],
    doc: "Optional field with default"
  ],
  complex_field: [
    type: {:or, [:atom, :string, {:struct, MyStruct}]},
    required: false
  ]
]
```

## Important Implementation Details

### 1. Compile-Time vs Runtime

- **DSL processing happens at compile time**
- Transformers and verifiers run during compilation
- Generated code is optimized for runtime performance
- Use `persist/3` to cache expensive computations

### 2. Error Handling

Always provide context in errors:
```elixir
{:error,
 Spark.Error.DslError.exception(
   message: "Clear error message",
   path: [:section, :subsection],  # DSL path
   module: module,                  # Module being compiled
   location: annotation             # Source location (when available)
 )}
```

### Error Location Information

When creating DslErrors, include location information whenever possible to help developers quickly identify the source of issues:

```elixir
# For entity-related errors, get entity annotations
entity_location = Spark.Dsl.Entity.anno(entity)

# For section-related errors, get section annotations
section_location = Spark.Dsl.Transformer.get_section_anno(dsl_state, [:section_path])

# For option-related errors, get option annotations
option_location = Spark.Dsl.Transformer.get_opt_anno(dsl_state, [:section_path], :option_name)

# Include in DslError
{:error,
 Spark.Error.DslError.exception(
   message: "Detailed error message",
   path: [:section_path],
   module: module,
   location: entity_location  # or section_location, option_location
 )}
```

## Common Gotchas

### 1. Compilation Deadlocks
```elixir
# WRONG - Causes deadlock
def transform(dsl_state) do
  module = get_persisted(dsl_state, :module)
  module.some_function()  # Module isn't compiled yet!
end

# RIGHT - Use DSL state
def transform(dsl_state) do
  entities = get_entities(dsl_state, [:section])
  # Work with DSL state, not module functions
end
```

### 2. Extension Order
- Extensions are processed in order
- Later extensions can modify earlier ones
- Use transformer ordering for dependencies

## Performance Considerations

1. **Compilation Performance**
   - Heavy transformers slow compilation
   - Cache expensive computations with `persist/3`
   - Use verifiers instead of transformers when possible

2. **Runtime Performance**
   - DSL processing has zero runtime overhead
   - Generated code is optimized
   - Info modules cache DSL data efficiently

3. **Memory Usage**
   - DSL state is cleaned up after compilation
   - Runtime footprint is minimal
   - Use structs efficiently in entities

## Summary

Spark enables:
- Clean, declarative DSL syntax
- Compile-time validation and transformation
- Extensible architecture
- Excellent developer experience

When coding with Spark:
1. Think in terms of entities, sections, and extensions
2. Leverage compile-time processing for validation
3. Use transformers for complex logic
4. Test DSLs thoroughly
5. Provide clear error messages with location information
6. Use annotation introspection for better debugging
7. Document your DSLs well


<!-- spark-end -->
## Standard Ecosystem Modules

All ecosystem packages should use shared building blocks consistently.

## Zoi Schemas

Use Zoi as the canonical schema and struct validation library.

Pattern:

```elixir
defmodule MyPackage.Model do
  @moduledoc """
  Brief description of what this model represents.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string(),
              name: Zoi.string() |> Zoi.nullish(),
              tags: Zoi.array(Zoi.string()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for this struct."
  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc "Builds a new struct from a map, validating with Zoi."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

  @doc "Like new/1 but raises on validation errors."
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
    end
  end
end
```

Zoi checklist:
- Core structs define an `@schema` using `Zoi.struct(__MODULE__, ...)`.
- `@type t :: unquote(Zoi.type_spec(@schema))` is present.
- `@enforce_keys` and `defstruct` are derived via `Zoi.Struct`.
- `schema/0`, `new/1`, and optionally `new!/1` are defined.
- Validation logic lives in the Zoi schema, not scattered across callers.

## Module Namespace Convention

Use `Jido.<PackageName>` as the canonical public namespace for Jido ecosystem packages.

In Elixir terms, the package root should be a predictable top-level module such as `Jido.Browser`, `Jido.Signal`, or `Jido.Action`. Extend from that root only when describing a real subdomain, for example `Jido.Browser.Session` or `Jido.Browser.Actions.Navigate`.

Avoid inventing an extra branded root like `Jido.BrowserCamelCase` when `Jido.Browser` is the package namespace, and avoid treating a deeper nested module as the package's canonical public entrypoint when the real package root should stay at `Jido.<PackageName>`.

Namespace checklist:
- The primary public package root is `Jido.<PackageName>`.
- Nested modules extend a real package root, not a one-off naming convention.
- Contributor docs, examples, and reviews refer to the canonical package root consistently.

## Splode Errors

Use Splode for error composition and classification. Keep error types tight and specific to the package.

Pattern:

```elixir
defmodule MyPackage.Error do
  @moduledoc """
  Centralized error handling for MyPackage using Splode.

  Error classes are for classification; concrete `...Error` structs are for raising/matching.
  """

  use Splode,
    error_classes: [
      invalid: Invalid,
      execution: Execution,
      config: Config,
      internal: Internal
    ],
    unknown_error: __MODULE__.Internal.UnknownError

  defmodule Invalid do
    @moduledoc "Invalid input error class for Splode."
    use Splode.ErrorClass, class: :invalid
  end

  defmodule Execution do
    @moduledoc "Execution error class for Splode."
    use Splode.ErrorClass, class: :execution
  end

  defmodule Config do
    @moduledoc "Configuration error class for Splode."
    use Splode.ErrorClass, class: :config
  end

  defmodule Internal do
    @moduledoc "Internal error class for Splode."
    use Splode.ErrorClass, class: :internal

    defmodule UnknownError do
      @moduledoc false
      defexception [:message, :details]
    end
  end

  defmodule InvalidInputError do
    @moduledoc "Error for invalid input parameters."
    defexception [:message, :field, :value, :details]
  end

  defmodule ExecutionFailureError do
    @moduledoc "Error for runtime execution failures."
    defexception [:message, :details]
  end

  @spec validation_error(String.t(), map()) :: InvalidInputError.t()
  def validation_error(message, details \\ %{}) do
    InvalidInputError.exception(Keyword.merge([message: message], Map.to_list(details)))
  end

  @spec execution_error(String.t(), map()) :: ExecutionFailureError.t()
  def execution_error(message, details \\ %{}) do
    ExecutionFailureError.exception(message: message, details: details)
  end
end
```

Splode checklist:
- A single `MyPackage.Error` module exists.
- It uses a small set of error classes such as `:invalid`, `:execution`, `:config`, and `:internal`.
- Concrete exception structs end in `Error` and are package-specific.
- Helpers like `validation_error/2` and `config_error/2` exist for common errors.
- External errors are normalized to `MyPackage.Error` types.

## Ogol Refactoring Policy

This codebase should prefer aggressive deletion over compatibility layering.

- When introducing a new canonical path, remove the superseded path in the same refactor unless there is a concrete blocker.
- Do not keep parallel representations alive "just in case" without an explicit short-lived migration reason.
- Prefer one source shape, one normalized runtime shape, and one UI shape for the same concept.
- If a refactor only adds adapters, shims, or fallback branches without deleting old code, treat that as incomplete work.
- Reduce ceremony when possible:
  - infer defaults instead of forcing repeated boilerplate
  - remove obsolete options once a better model exists
  - collapse redundant abstractions instead of wrapping them again
- Before finishing a refactor, explicitly look for:
  - dead code paths
  - now-redundant fields/options
  - compatibility helpers that can be deleted
  - old tests/examples that still teach the superseded approach
- Favor replacing old examples with the new canonical style instead of keeping both old and new patterns around.

<!-- usage-rules-end -->
