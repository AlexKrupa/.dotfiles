use clap::{Parser, Subcommand};
use watchd::{client, daemon, engine};

#[derive(Parser)]
#[command(name = "watchd", about = "The watch daemon, its check engine, and its client")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

/// Each command parses its own flags, because the skills and the tests compare the error texts.
#[derive(Subcommand)]
enum Commands {
    /// One check of the GitLab project or MRs of a repo.
    #[command(disable_help_flag = true)]
    Engine {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// The daemon, which a client starts.
    Daemon,
    /// Save the watch of the session and exit: --session ID [--repo PATH] [--interval SECONDS] [--fresh] [--review] [--mr IID]...
    #[command(disable_help_flag = true)]
    Watch {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Wait for the events of the watches of the session, one JSON line each: --session ID --owner-pid PID.
    #[command(disable_help_flag = true)]
    Wait {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// End the watch of the session for the repo and mode: --session ID [--repo PATH] [--review] [--mr IID]...
    #[command(disable_help_flag = true)]
    Unsubscribe {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// The daemon, the last poll of each repo, and the subscriptions.
    Status,
    /// The kind of work of the worktree of the current folder: KIND.
    #[command(disable_help_flag = true)]
    Kind {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// The router result of an opened event of the hub: --iid IID --action bump|review|none [--repo PATH].
    #[command(disable_help_flag = true)]
    Route {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// Diagnostics.
    Debug {
        #[command(subcommand)]
        command: DebugCommand,
    },
    /// The sidebar state, then the event log lines and the sidebar changes, one JSON line each.
    Follow {
        /// First the event log lines with a greater id.
        #[arg(long)]
        after: Option<u64>,
    },
    /// The newest hub report of the repo, drawn again after each change: [--repo PATH].
    #[command(disable_help_flag = true)]
    Board {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
    /// The Markdown report of the last delivery: [--repo PATH] [--review] [--mr IID]... <JSON.
    #[command(disable_help_flag = true)]
    Report {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        args: Vec<String>,
    },
}

#[derive(Subcommand)]
enum DebugCommand {
    /// All state as JSON, also the parts in memory only.
    State,
}

#[tokio::main]
async fn main() {
    let code = match Cli::parse().command {
        Commands::Engine { args } => engine::main(args).await,
        Commands::Daemon => daemon::main().await,
        Commands::Watch { args } => client::watch(args).await,
        Commands::Wait { args } => client::wait(args).await,
        Commands::Unsubscribe { args } => client::unsubscribe(args).await,
        Commands::Status => client::status().await,
        Commands::Kind { args } => client::kind(args).await,
        Commands::Route { args } => client::route(args).await,
        Commands::Report { args } => client::report(args).await,
        Commands::Board { args } => client::board(args).await,
        Commands::Debug {
            command: DebugCommand::State,
        } => client::debug_state().await,
        Commands::Follow { after } => client::follow(after).await,
    };
    std::process::exit(code);
}
