# Code Style

## Elixir Style

- Prefer pattern matching on function heads over if/else or case statements in function bodies
- Extract logic into small, well-named private functions rather than inline conditionals
- Use multiple function clauses with pattern matching for different cases (e.g., empty list, nil, populated list)
- Pipelines should be clean and readable; extract complex steps into named helper functions

## Comments

- Avoid inline comments that explain easily readable code (e.g. `penalty = 100  # 100 seconds penalty`)
- Prefer well-named functions over comments - if code needs explanation, extract it into a descriptively named function
- Module/function `@doc` and `@moduledoc` documentation is fine for public APIs
- In tests, docstrings explaining the test scenario are acceptable since they describe intent and expectations
