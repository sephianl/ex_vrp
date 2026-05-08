code = """
# Leading comment
x = 1 # Inline comment
# Another comment
y = 2
"""

IO.puts("=== Original ===")
IO.puts(code)

# Parse with sourceror (embeds comments in metadata)
ast = Sourceror.parse_string!(code)

# Now simulate what Credence does: use Macro.postwalk for transformation
modified = Macro.postwalk(ast, fn node -> node end)

# Convert back
IO.puts("=== After round-trip ===")
result = Sourceror.to_string(modified)
IO.puts(result)
