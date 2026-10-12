# Plant 3D daily report automation

Runs the project's Plant 3D report commands every morning from Windows Task Scheduler,
with no one at the keyboard.

```
Task Scheduler (06:30, interactive session)
  └─ powershell.exe Run-Plant3DReports.ps1 -ConfigPath config.json
       ├─ writes  Logs\<timestamp>\reports.scr      (generated AutoCAD script)
       ├─ starts  acad.exe "<project dwg>" /product PLNT3D /b reports.scr
       │     Plant 3D loads the project that owns the drawing,
       │     runs PreCommands + ReportCommands, saves, quits
       ├─ waits with a timeout (kills + screenshots if stuck on a dialog)
       └─ writes  Logs\<timestamp>\run.log, acad-commandlog.txt, DONE.txt
```

## Is there a better way than "open Plant 3D, load the project, open a blank file"?

Mostly yes, with three changes to the idea:

1. **Don't open a blank file. Open an empty drawing that belongs to the project.**
   Plant 3D attaches the project to the drawing it opens, so starting AutoCAD with a
   project drawing on the command line loads the project for you. A plain `Drawing1.dwg`
   is not part of any project and the project would only load if Plant 3D happens to
   remember it from last time. Create one empty drawing in the project (for example
   `Plant 3D Models\_DailyReports.dwg`) and keep it for this purpose only.

2. **Drive the commands with a startup script, not with UI automation.**
   `acad.exe` accepts `/b <script.scr>`, which runs a script as soon as the drawing is
   open. No SendKeys, no window-title hunting. The runner generates the `.scr` from the
   JSON config on every run, so the list of commands lives in config, not in a hand-edited
   script.

3. **If the reports are Report Creator reports, skip AutoCAD completely.**
   Plant 3D ships `PnPReportCreator.exe` (in the `PLNT3D` folder), which Autodesk documents
   as scriptable with `/PROJECT`, `/CONFIG`, `/DWG`, `/HIDDEN` and `/QUIET`. That runs in
   seconds, needs no interactive desktop and cannot get stuck on a drawing dialog. The
   runner supports this as `"Mode": "ReportCreator"`. It only helps if your reports are
   `.rcf` report configurations; custom LISP/.NET report *commands* still need the AutoCAD
   session (`"Mode": "Acad"`).

What does **not** work: `accoreconsole.exe` (the headless AutoCAD). It can run scripts
and NETLOAD assemblies, but the Plant 3D project/database layer is not available in it,
so project-aware commands fail there.

One constraint you cannot script around: AutoCAD is a desktop app, so the scheduled task
must run **in a logged-on interactive session**. "Run whether user is logged on or not"
puts it in a hidden session where AutoCAD and the Autodesk licensing sign-in do not work.
The usual setup is a dedicated reporting PC or VM that auto-logs-on and locks its screen;
a locked desktop is fine.

## Setup

1. Copy this folder to the reporting PC, e.g. `C:\Plant3D\Automation`.
2. In the Plant 3D project, create an empty drawing dedicated to reports
   (`Plant 3D Models\_DailyReports.dwg`). The runner saves it at the end of each run, so it
   must not be read-only and nobody else should have it open.
3. `copy config.sample.json config.json` and edit it (reference below).
   At minimum set `ProjectDrawing` and `ReportCommands`.
4. If your report commands come from a LISP/.NET file, load it in `PreCommands` and add its
   folder to **Options > Files > Trusted Locations** in the Plant 3D profile, otherwise
   `SECURELOAD` pops a dialog and the run hangs until the timeout.
5. Make sure the Windows user that will run the task is signed in to Autodesk in
   Plant 3D (named-user licensing) and that Plant 3D opens the project without prompts
   when started by hand.
6. Dry run from PowerShell to see the generated script and command line:

   ```powershell
   .\Run-Plant3DReports.ps1 -ConfigPath .\config.json -DryRun
   ```

7. Real run, watch it work once:

   ```powershell
   .\Run-Plant3DReports.ps1 -ConfigPath .\config.json
   ```

8. Register the task (elevated PowerShell):

   ```powershell
   .\Register-Plant3DReportTask.ps1 -Time 06:30 -Weekdays
   Start-ScheduledTask -TaskName 'Plant3D Daily Reports'   # test it immediately
   ```

## config.json reference

| Key | Meaning |
|---|---|
| `Mode` | `Acad` (default) runs commands in a Plant 3D session. `ReportCreator` runs `.rcf` reports headless. |
| `AcadExe` | Path to `acad.exe`. Default is the AutoCAD 2026 location. |
| `Language` | Passed as `/language`. Default `en-US`. |
| `Profile` | Optional `/p` profile name. Leave empty to use the Plant 3D toolset default. |
| `ProjectDrawing` | The dedicated empty drawing inside the project. Opening it loads the project. |
| `StartupDelayMs` | Pause at the start of the script so Plant 3D finishes loading the project before commands run. Default 15000. |
| `PreCommands` | Lines run before the reports, e.g. `(load "C:/Tools/Reports.lsp")` or `NETLOAD` lines. |
| `ReportCommands` | One command (or script line) per entry, run in order. |
| `TimeoutMinutes` | Kill AutoCAD after this long. Default 45. |
| `LogDir` | One sub-folder per run is created here. |
| `KeepLogDays` | Run folders older than this are deleted. 0 keeps everything. |
| `AllowWhenAcadRunning` | By default the run aborts if `acad.exe` is already open so a live session is not disturbed. |
| `ReportCreatorExe` | Path to `PnPReportCreator.exe` (ReportCreator mode). |
| `ReportCreatorJobs` | Array of `{ "Project": "...\\Project.xml", "Config": "...\\Report.rcf", "Drawings": ["optional", "dwg", "list"] }`. |

Script line rules for `PreCommands` / `ReportCommands`: one line per entry, each entry must
be a complete command including any answers it needs (e.g. `MYREPORT` then `"C:/out/x.xlsx"`
as the next entry if the command prompts for a path). Never leave an entry empty: an empty
line in an AutoCAD script is an Enter, which repeats the previous command. Any command that
opens a dialog box will stall the run; use the command-line variant (`-COMMAND`) where one
exists.

## What the generated script does

```
(setvar "CMDECHO" 0)
(setvar "EXPERT" 5)              ; suppress "Are you sure?" style prompts
_.DELAY 15000                    ; let the project finish loading
(setvar "LOGFILEMODE" 1)         ; capture command-line output
<PreCommands>
<ReportCommands>
(setvar "LOGFILEMODE" 0)
(vl-file-copy (getvar "LOGFILENAME") ".../acad-commandlog.txt")
(... write DONE.txt ...)         ; marker the runner checks for success
_.QSAVE                          ; clears the modified flag
_.QUIT                           ; exits without a "save changes?" dialog
```

## Exit codes and troubleshooting

| Exit | Meaning | Look at |
|---|---|---|
| 0 | Commands finished, AutoCAD exited cleanly | `DONE.txt` exists |
| 1 | AutoCAD exited but never reached the end of the script | `acad-commandlog.txt`, a command may have errored or prompted for extra input |
| 2 | Timeout, AutoCAD was killed | `timeout.png` shows the dialog it was stuck on |
| 3 | Pre-flight failure | `run.log` (missing file, bad JSON, AutoCAD already running) |

Common causes of a stuck run:

- A dialog: Autodesk sign-in, "drawing belongs to a different project", Drawing Recovery
  Manager after a previous kill, SECURELOAD trusted-path prompt, a report command that
  uses a dialog for its output path.
- The project is a collaboration (ACC / BIM 360) project and the cached login expired.
- The task was registered to run whether the user is logged on or not.

After a timeout kill, AutoCAD may show the Drawing Recovery Manager on the next start.
Open Plant 3D by hand once, dismiss it, and the next scheduled run is clean again.

## Sources

- Autodesk, "Plant 3D: How can I control Report Creator's execution?"
  https://blog.autodesk.io/plant-3d-how-can-i-control-report-creators-execution/
- Autodesk forums, Plant 3D batch processing with Core Console / .NET
  https://forums.autodesk.com/t5/net-forum/cycle-through-project-drawings-plant-3d/td-p/11162418
- Hagerman, launching Plant 3D with `/product PLNT3D /language "en-US"`
  https://blog.hagerman.com/running-the-cache-purger-automatically-when-launching-autocad-plant-3d
