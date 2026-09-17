# Foder — Working Demo Prompts

Curated, tested, and verified prompts demonstrating Foder's capabilities as a local, offline AI coding agent powered by Ollama.

All execution runs 100% locally on your machine with zero cloud dependencies and zero API keys.

```bash
foder                          # Start interactive agent REPL
foder "your prompt here"       # Single prompt non-interactive mode
```

---

## 1. Workspace Inspection & File Discovery

Test Foder's ability to explore and understand your project directory safely using the `dir_list` tool.

```
inspect the workspace and list the files
```

**What to expect:**
- Foder opens the execution trace:
  ```
  ┌ PLANNING ──────────────────────────────────────────┐
  ≡ list    .
      [ok]  HelloWorld.java  password_generator.py
  └────────────────────────────────────────────────────┘  1 tool(s) · DONE
  ```
- Lists all active project files and explains directory structure.

---

## 2. File Creation with Logic & Automatic Syntax Verification

Test Foder's ability to generate clean code directly to workspace files using `file_write` while automatically verifying syntax via AST parsing.

```
write a python script calculator.py with add, subtract, multiply, and divide functions
```

**What to expect:**
- Foder writes `calculator.py` with complete working functions.
- Foder automatically runs AST syntax verification in the background before confirming.
- If any invalid syntax (e.g. `def subtract(x,y)::`) is generated, Foder's self-correction loop catches it and fixes it automatically before returning.
- Instant confirmation:
  ```
  Created `calculator.py` and verified syntax successfully.
  ```

---

## 3. Code Execution & Testing via Shell

Test Foder's ability to run code and verify runtime behavior using `shell_exec` (scoped safely to the workspace).

```
run calculator.py to test the arithmetic functions
```

**What to expect:**
- Foder invokes `python3 calculator.py`.
- The execution trace shows the command output live:
  ```
  ┌ PLANNING ──────────────────────────────────────────┐
  $ exec    python3 calculator.py
      > 4 + 2 = 6
      [ok]
  └────────────────────────────────────────────────────┘  1 tool(s) · DONE
  ```
- Summarizes the runtime test results.

---

## 4. Diff-Based Refactoring & Editing

Test surgical file editing using `file_edit` (finding and replacing exact code blocks without re-dumping the entire file).

```
modify calculator.py to add a power(x, y) function that returns x raised to y
```

**What to expect:**
- Foder locates the existing functions in `calculator.py` and applies a diff replacement.
- AST syntax verification validates the modified file.
- Confirmation:
  ```
  Updated calculator.py and verified syntax successfully.
  ```

---

## 5. Code Understanding & Explanation (Read-Only)

Test Foder's ability to inspect and explain existing workspace code using `file_read`.

```
read calculator.py and explain the functions implemented in it
```

**What to expect:**
- Foder calls `file_read` to load lines from the file.
- Outlines each function (`add`, `subtract`, `multiply`, `divide`, `power`) and their parameters.
- Does not modify any files or execute unnecessary commands.

---

## 6. Polyglot Language Support (Java / C / Bash)

Foder is not limited to Python. It detects classes, compilers, and file extensions across multiple languages.

```
can you create a java file and write a hello world program
```

**What to expect:**
- Foder creates `HelloWorld.java` with a valid `public class HelloWorld`.
- Verifies brace balance and class structure.
- Prepares runnable code:
  ```bash
  !java HelloWorld.java
  ```

---

## 7. Useful REPL Shortcuts & Slash Commands

Inside the `foder` interactive prompt:

| Command | Action |
|---|---|
| `!ls` | List current directory contents with colored extensions |
| `!pytest` | Run your project tests directly from the REPL |
| `!<cmd>` | Run any workspace shell command directly |
| `@filename` | Inject file contents into your prompt context |
| `/context` | Display detected project stack, entry points, and test framework |
| `/doctor` | Run full system health check (Python, Ollama, PATH, models) |
| `/plan <task>` | Formulate a structured multi-step plan before writing code |
| `/models` | List all locally installed Ollama models |
| `/theme` | Switch between 6 terminal color themes |
| `/clear` | Reset conversation history |
