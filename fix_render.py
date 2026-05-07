import sys

content = open('src/tui/render.zig').readlines()

# Insert before line 129 (0-indexed: 128)
insert1 = [
    '    if (self.show_command_palette) {\n',
    '        try components.printCommandPalette(self, stdout, rows, cols);\n',
    '        try stdout.writeAll("\\x1b[?25l");\n',
    '        return;\n',
    '       }\n',
    '\n',
]
for i, line in enumerate(insert1):
    content.insert(128 + i, line)

# Find the second occurrence (originally line 340, now shifted by 6)
# Search for "if (prompt_room_for_input == 0)"
for i, line in enumerate(content):
    if 'prompt_room_for_input == 0' in line and 'cursor_row' in line:
        # Go back to find the show_model_modal block
        j = i - 1
        while j >= 0 and content[j].strip() == '':
            j -= 1
        # j should be at the closing brace of show_model_modal block
        # Go back further to find the start
        k = j
        while k >= 0 and 'show_model_modal' not in content[k]:
            k -= 1
        # Insert before line k (0-indexed)
        insert2 = [
            '    if (self.show_command_palette) {\n',
            '        try components.printCommandPalette(self, stdout, rows, cols);\n',
            '        try stdout.writeAll("\\x1b[?25l");\n',
            '        return;\n',
            '       }\n',
            '\n',
        ]
        for idx, line in enumerate(insert2):
            content.insert(k + idx, line)
        break

open('src/tui/render.zig', 'w').writelines(content)
print("Done")
