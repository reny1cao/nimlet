import Foundation

/// nimlet — a headless Nimlet client.
///
/// Two jobs. One is diagnostic: it exercises the host's delivery path
/// (focus → paste → Return) without a phone, which is how you tell a dictation
/// problem from a delivery problem. The other is `nimlet event`, which is what a
/// user's own agent hook calls so every connected phone learns that a run
/// finished.

let helpText = """
nimlet — talk to Nimlet on this Mac from a script.

usage: nimlet <command> [options]

  pair --code CODE [--host NAME]
        Store the pairing code from Nimlet Settings → Agents so later
        commands need no arguments. --host picks one Mac by name when
        several advertise.

  list
        The host's targets: id, name, kind, and whether a tmux target is
        pinned to a stable %id or to a spec that renumbers.

  target remove NAME|ID
        Forget a target. The pane or app is untouched.

  target add --tmux PANE [--name NAME] [--no-auto-submit]
        Add a tmux target without opening Settings. PANE may be a pane id
        (%3) or a spec (codex:0.1); a spec is resolved to its %id and only
        the %id is stored. --no-auto-submit means Nimlet may type into the
        pane but will never press Return on it.

  send [TEXT] [--target NAME|ID] [--submit|--no-submit]
        Deliver text. TEXT comes from the argument or, without one, stdin.
        Without --target the host's currently selected target is used.
        Prints what the host reports and exits non-zero if it failed.

  event done|waiting|failed [--target NAME|ID | --pane %ID] [--note TEXT]
                            [--agent NAME] [--hook]
        Report that an agent changed state. The host fans it out to every
        connected phone. This is the command to put in an agent hook. Run
        inside a tmux pane it needs no --target: the pane ($TMUX_PANE) names
        the target. Outside one — a desktop app, a terminal without tmux — an
        app target for the app it runs inside is used, and failing that it
        reports as --agent. --hook reads the hook payload on stdin for the
        note ("Wants to run: npm test") and prints nothing, because a hook's
        stdout is the agent's to read.

  answer --hook [--agent "Claude Code"|Codex] [--target NAME|ID | --pane %ID]
        A PermissionRequest hook that lets the phone answer. Reads the hook
        payload on stdin and puts the agent's permission prompt — or, in
        Claude Code, its question and choices — on the phone and in the menu
        bar, then prints the answer for the agent: allow, deny with a reason,
        "don't ask again", or the chosen answers. Prints nothing if nobody
        answers within the wait set in Settings → Agents, which leaves the
        agent's own prompt on the Mac: nothing is approved by waiting. In
        Codex, which hides its prompt while a hook runs, it only tells the
        phone while somebody is using the Mac.

  ask [DETAIL] --title TEXT [--target NAME|ID | --pane %ID]
      [--kind command|edit|network|other] [--for SECONDS]
        Ask the phones for a decision and block until one comes back. DETAIL
        is the thing being decided — the command, the path, the URL — from the
        argument, --detail or stdin. Exit 0 means approved; every other exit
        code, including a timeout and an unreachable Mac, means not approved.
        Without --for it waits as long as Settings → Agents says.

  gate [--target NAME|ID | --pane %ID] [--tools Bash,Write] [--for SECONDS]
        A PreToolUse hook in one command: reads the hook payload on stdin,
        asks, then exits 0 to allow or 2 to block. A tool outside --tools is
        allowed without asking. Like `event`, it finds its target from the
        tmux pane it runs in. Without --for it waits as long as Settings →
        Agents says, then blocks.

  menu BUNDLEID [--refresh]
        What Nimlet reads in that app's menu bar, and which of it becomes
        buttons on the phone. --refresh walks the menus again instead of
        using what the Mac already read. This is how to check a row without
        picking up the phone.

  pending
        What is waiting for a decision right now, with the time each has left.

  decide ID approve|deny [--reason TEXT] [--answer TEXT ...] [--always]
                          [--hand-back]
        Answer from the Mac instead of the phone. A reason reaches the agent
        with the denial, so it does not simply ask again. A question is
        approved with one --answer per question; --always takes the agent's
        own "don't ask again"; --hand-back leaves it to the agent's prompt.

  bench --hz N [--seconds S]
        Drive the pointer at N Hz and report send-side timing, so host-side
        jitter can be told apart from client-side jitter.

  hook [--target NAME|ID] [--approve]
        Print a Claude Code Stop hook that calls `nimlet event done`, or with
        --approve a PreToolUse hook that routes each command to your phone.
        It only prints: nothing here writes to your settings. Nimlet's own
        Settings → Agents installs the same hooks with one click.

This binary ships inside Nimlet.app, at
  /Applications/Nimlet.app/Contents/Helpers/nimlet
and is paired and approved from Settings → Agents on the Mac.

options (any command):
  --json          machine-readable result on stdout; warnings and errors
                  stay on stderr
  --timeout S     how long to wait for the Mac (default 15, and 5 for
                  `event`, which runs from a hook)
  -h, --help      this text

what this is actually worth using:
  For a tmux target, `nimlet send` is a Bonjour lookup and a TLS handshake to
  do what `tmux send-keys -t %3 'text' Enter` does on its own — reach for
  tmux unless you are talking to the host anyway. What it does that nothing
  else does easily is the app and frontmost target kinds (raise by bundle
  id, paste, press Return), which osascript handles badly, and `nimlet event`,
  which is the only way to get an agent's state onto the phones.

exit codes:
  0  did what was asked
  1  the host refused, or the delivery came back failed
  2  bad arguments, unknown target, or not paired yet
  3  no host found, or the connection never came up
  4  connected, but nothing came back in time — and, for `ask`, nobody
     answered before the request expired into its denial

Approvals fail closed. A request nobody answers denies itself, and so does one
that cannot reach the Mac at all, so `nimlet ask ... || exit 2` in a hook is safe
on every path including the ones nobody tests. `answer` fails to the agent's
own prompt instead: it never prints a decision nobody made.

Configuration is ~/.config/nimlet/config.json, mode 0600 — it holds the
pairing code, which is what stands between the local network and keystroke
injection on this Mac.
"""

func run() -> Int32 {
    var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
    do {
        if arguments.flag("--help", "-h") {
            print(helpText)
            return 0
        }
        Output.json = arguments.flag("--json")
        let timeout: Double? = try arguments.option("--timeout").map { raw in
            guard let seconds = Double(raw), seconds > 0 else {
                throw CLIError(.usage, "--timeout wants a number of seconds")
            }
            return seconds
        }

        guard let command = arguments.takePositional() else {
            FileHandle.standardError.write(Data((helpText + "\n").utf8))
            return CLIError.Code.usage.rawValue
        }

        switch command {
        case "pair": try commandPair(&arguments)
        case "list": try commandList(&arguments, timeout: timeout)
        case "target": try commandTarget(&arguments, timeout: timeout)
        case "send": try commandSend(&arguments, timeout: timeout)
        case "event": try commandEvent(&arguments, timeout: timeout)
        case "ask": try commandAsk(&arguments, timeout: timeout)
        case "gate": try commandGate(&arguments, timeout: timeout)
        case "answer": try commandAnswer(&arguments, timeout: timeout)
        case "menu": try commandMenu(&arguments, timeout: timeout)
        case "pending": try commandPending(&arguments, timeout: timeout)
        case "decide": try commandDecide(&arguments, timeout: timeout)
        case "bench": try commandBench(&arguments, timeout: timeout)
        case "hook": try commandHook(&arguments)
        default: throw CLIError(.usage, "unknown command: \(command) (try `nimlet --help`)")
        }
        return 0
    } catch let error as CLIError {
        Output.fail(error.message)
        return error.code.rawValue
    } catch {
        Output.fail(error.localizedDescription)
        return CLIError.Code.refused.rawValue
    }
}

exit(run())
