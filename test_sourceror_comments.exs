code = """
# Leading comment
x = 1 # inline comment
# Another comment
y = 2
"""

IO.puts("=== Original code ===")
IO.puts(code)

# Parse with comments embedded
ast = Sourceror.parse_string!(code)

IO.puts("\n=== Has leading/trailing comments in metadata? ===")
IO.inspect(ast, limit: :infinity)

# Simulate AST modification (like Credence does with identity)
modified = Macro.postwalk(ast, fn node -> node end)

# Convert back to string
IO.puts("\n=== After round-trip (Sourceror.to_string) ===")
result = Sourceror.to_string(modified)
IO.puts(result)
