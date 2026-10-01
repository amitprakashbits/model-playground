# Test results

Run on October 02, 2026 on an Apple Silicon Mac with 16 GB of unified memory (macOS 26.7), Python 3.14, mlx-lm 0.32, AirLLM 4.0.

| Suite | Result |
|---|---|
| Backend end-to-end (`tests/test_backend_e2e.py`) | **23/23 passed** |
| App self-test (`ModelPlayground --selftest`) | **23/23 passed** |
| Qwen3.5-9B in-app model test (`MP_TEST_MODEL=Qwen3.5-9B`) | **9/9 passed**, plus benchmarks below |

Run everything with `./scripts/run_tests.sh`.

## Qwen3.5-9B on a 16 GB Mac

| | Qwen3.5-9B (4-bit, 6 GB) | Qwen3-4B-2507 (4-bit, 2.3 GB) |
|---|---|---|
| Generation speed | ~20 tok/s | ~38–52 tok/s |
| Quiz (13 auto-graded questions) | **11/13** (missed: siblings riddle, "exactly three words") | 10/13 (missed: 17×23, siblings riddle, three words) |
| Long-context retrieval, 1K–32K tokens × 3 depths | **18/18** | 18/18 |
| Prompt processing at 32K tokens | 115 tok/s (~4.7 min per 32K prompt) | 125 tok/s |
| Peak memory at 32K tokens | 9.6 GB | 9.6 GB |
| Bat-and-ball riddle with thinking | Correct (5 cents) after 1,405 words of reasoning | not tested |
| 5.5K-token document Q&A, 8-bit KV cache | Correct (found the technician and date) | not tested |

Takeaways: Qwen3.5-9B is the strongest model tested on this Mac and handled every long-context test up to 32K tokens. It is about 2.5× slower than Qwen3-4B, which is nearly as reliable on retrieval. Long prompts are bounded by prompt processing speed (about 115–150 tok/s), not by context window size.

## Bugs found and fixed during testing

- **Qwen 3.5 reasoning was shown as the answer.** Its chat template opens `<think>` inside the prompt, so replies only contained the closing tag. The backend now emits the opening tag and the app folds reasoning correctly. Follow-up latency dropped from 26.5 s to 1.4 s because reasoning is no longer resent as history.
- **The judge returned 0/10 with long-thinking models.** The judge now runs with built-in thinking off (its prompt already asks for a reference answer first), and the parser ignores any reasoning before `</think>`.
- **Tiny judges rate everything 10/10.** Under about 4B parameters, judges failed to penalize a wrong answer (12×12 = 100). The app warns about this and defaults to the largest installed model; Qwen3-4B correctly marked down a factual error.
- **Download progress stuck at 0%.** Xet transfers buffer whole files before writing; downloads now use plain HTTP so progress is accurate.
- **"Reliable context" overstated results** when a shorter length failed; it now requires every shorter length to pass.
- **Compare looked broken with no models selected** (send button disabled with no explanation). It now pre-fills installed models and explains what's missing.
- **Port conflicts.** The engine now picks a free port on each launch and verifies it is talking to its own backend.

## Backend end-to-end

| | Check | Detail |
|---|---|---|
| ✅ | health identifies the app | {'ok': True, 'app': 'model-playground', 'version': '1.0.0', 'busy': False, 'loaded': None} |
| ✅ | catalog has 60+ models | 106 entries |
| ✅ | catalog entries have context sizes |  |
| ✅ | system info | {'total_ram_gb': 17.2, 'available_ram_gb': 8.2, 'free_disk_gb': 125.9} |
| ✅ | downloads finish | mlx-community/Qwen3-0.6B-4bit=done ; mlx-community/LFM2.5-1.2B-Instruct-4bit=done  |
| ✅ | download progress reaches total |  |
| ✅ | downloaded models are listed | mlx-community/LFM2.5-1.2B-Instruct-4bit, mlx-community/Qwen3-0.6B-4bit, mlx-community/Qwen3-4B-Instruct-2507-4bit, mlx-community/Qwen3.5-9B-4bit, TinyLlama/Tiny |
| ✅ | hf cache models are listed |  |
| ✅ | chat Qwen3-0.6B-4bit streams an answer | '12 multiplied by 12 is 144.' |
| ✅ | chat Qwen3-0.6B-4bit reports stats | 243.31 tok/s, 14 tokens |
| ✅ | chat LFM2.5-1.2B-Instruct-4bit streams an answer | 'The result of 12 multiplied by 12 is 144.' |
| ✅ | chat LFM2.5-1.2B-Instruct-4bit reports stats | 179.18 tok/s, 14 tokens |
| ✅ | multi-turn context with 8-bit KV cache | "Hello! I'm Zorblat. If you have any questions or need help, feel free to ask! 😊" |
| ✅ | tokenize counts per model | {'/Users/amitprakash/ModelPlayground/models/mlx-community__Qwen3-0.6B-4bit': 201, '/Users/amitprakash/ModelPlayground/models/mlx-community__LFM2.5-1.2B-Instruct |
| ✅ | judge returns a score per answer | [{"accuracy": 10.0, "helpfulness": 10.0, "clarity": 10.0, "overall": 10.0, "verdict": "12 * 12 is 144.", "raw": "```json\n{\n  \"reference\": \"12 multiplied by |
| ✅ | judge scores are in range | a=10.0, b=10.0 |
| ✅ | eval grades the quiz | 6/13 passed |
| ✅ | eval runs the context test | 1K tokens, depth 50%=pass, 2K tokens, depth 50%=pass |
| ✅ | catalog has powerful 32GB+ models |  |
| ✅ | stop cancels generation | 6 tokens |
| ✅ | worker is idle after stop |  |
| ✅ | missing model returns 404 |  |
| ✅ | unload frees the model |  |

## App self-test

| | Check | Detail |
|---|---|---|
| ✅ | engine starts on a free port | port 56525 |
| ✅ | catalog loads | 106 models |
| ✅ | installed models are found | LFM2.5-1.2B-Instruct-4bit, Qwen3-0.6B-4bit, Qwen3-4B-Instruct-2507-4bit, Qwen3.5-9B-4bit, TinyLlama-1.1B-Chat-v1.0 |
| ✅ | chat reply streams | 12 multiplied by 12 is 144. |
| ✅ | chat reply has stats | 235 tok/s, 14 tokens |
| ✅ | attachment is added |  |
| ✅ | model reads the attached file | PERIWINKLE |
| ✅ | regenerate replaces the last reply |  |
| ✅ | stop ends generation early | cancelled |
| ✅ | compare runs every model | Qwen3-0.6B: 218 chars ; LFM2.5-1.2B: 202 chars ; Qwen3-4B-2507: 272 chars  |
| ✅ | compare collects stats |  |
| ✅ | tokenizer comparison counts prompt tokens | Qwen3-0.6B=15, LFM2.5-1.2B=15, Qwen3-4B-2507=15 |
| ✅ | judge scores every answer | 10.0, 10.0, 4.0 |
| ✅ | judge scores are in range |  |
| ✅ | vote is recorded |  |
| ✅ | blind mode hides model names | Model A, Model B, Model C |
| ✅ | voting reveals names |  |
| ✅ | benchmarks run for each model | LFM2.5-1.2B err=none; Qwen3-0.6B err=none |
| ✅ | quiz is graded | LFM2.5-1.2B 4/13, Qwen3-0.6B 6/13 |
| ✅ | context test covers lengths and depths | LFM2.5-1.2B 9/9, reliable to 4K, Qwen3-0.6B 8/9, reliable to - |
| ✅ | runs recorded for leaderboard | 11 runs |
| ✅ | judged quality reaches leaderboard |  |
| ✅ | chats persist to disk |  |

## Qwen3.5-9B in-app test

| | Check | Detail |
|---|---|---|
| ✅ | engine starts |  |
| ✅ | model is installed | Qwen3.5-9B-4bit, 5.98 GB, 256K context |
| ✅ | chat | no thinking)  (19.5 tok/s, 52 tokens, 1.63s first token, 5.2 GB \| A good API design prioritizes simplicity and consistency by using intuitive naming convention |
| ✅ | reasoning is folded into a thought block | thought 1405 words |
| ✅ | reasoning reaches a correct final answer | 19.7 tok/s, 2503 tokens, 1.01s first token, 5.4 GB \| The ball costs 5 cents. |
| ✅ | markdown table answer | 19.7 tok/s, 206 tokens, 1.41s first token, 5.5 GB \| \| Language \| Speed \| Safety \| Learning Curve \| \| :--- \| :--- \| :--- \| :--- \| \| **Python** \| Mod |
| ✅ | long document Q&A | 8-bit KV cache)  (prompt 5459 tokens · 19.4 tok/s, 86 tokens, 41.31s first token, 7.0 GB \| Based on the text provided in the file, the backup generator at the  |
| ✅ | compare Qwen3.5-9B is answered and judged | 21.4 tok/s, 143 tokens, judge 10.0/10 · The answer is accurate, helpful, clear, and well within the word limit. |
| ✅ | compare Qwen3-4B-2507 is answered and judged | 51.8 tok/s, 107 tokens, judge 10.0/10 · The answer is accurate, helpful, and clear. |

Benchmarks (from the full run with 32K contexts):

| | Check | Detail |
|---|---|---|
| ✅ | benchmark Qwen3.5-9B | quiz 11/13, context 18/18, reliable to 32K, 115 tok/s prompt processing at 32K, peak 9.6 GB |
| ✅ | benchmark Qwen3-4B-2507 | quiz 10/13, context 18/18, reliable to 32K, 125 tok/s prompt processing at 32K, peak 9.6 GB |

## Screenshots

Captured by the self-test from the running app.

| | |
|---|---|
| ![Welcome](screenshots/02-welcome.png) | ![Chat with Qwen3.5-9B](screenshots/m1-chat.png) |
| Welcome | Chat with Qwen3.5-9B: folded reasoning, table, stats |
| ![Document Q&A](screenshots/m2-document.png) | ![Dark mode](screenshots/04-chat-dark.png) |
| Long document Q&A with an attachment | Dark mode |
| ![Compare](screenshots/05-compare-answers.png) | ![Stats](screenshots/06-compare-stats.png) |
| Compare: answers | Compare: speed and token charts |
| ![Quality](screenshots/m5-quality.png) | ![Blind](screenshots/07b-compare-blind.png) |
| Compare: AI judge | Blind arena |
| ![Benchmarks](screenshots/m3-benchmarks.png) | ![Leaderboard](screenshots/08-leaderboard.png) |
| Benchmarks: Qwen3.5-9B vs Qwen3-4B to 32K | Leaderboard |
| ![Library](screenshots/01-library.png) | |
| Model library | |
