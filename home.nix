{ pkgs, username, ... }:

{
  home.username = username;
  home.homeDirectory = "/Users/${username}";
  home.stateVersion = "25.05";

  # Let Home Manager manage itself
  programs.home-manager.enable = true;
  manual.manpages.enable = false;

  # ── CLI packages ──────────────────────────────────────────────
  home.packages = with pkgs; [
    # Core utils
    jq
    iperf3

    # Archive
    p7zip

    # Media
    ffmpeg
    pdf2svg

    # Cloud
    azure-cli

    # Networking / transfer
    mosh
    rclone

    # Modelops toolchain (see modelops/README.md)
    uv                              # Python project + venv manager
    python3Packages.huggingface-hub # `hf` CLI for downloads/uploads

    # GitHub Copilot CLI (`copilot` — standalone coding-agent CLI, not the gh extension)
    github-copilot-cli

    # Fonts (Nerd Fonts)
    nerd-fonts.fira-code
  ];

  # Apple container services are user-scoped and do not start containers after
  # reboot. Reconcile the runtime and Hermes container once the user logs in.
  launchd.agents.mana-hermes = {
    enable = true;
    config = {
      ProgramArguments = [
        "/Users/${username}/repo/mana/hermes/run.sh"
        "up"
      ];
      EnvironmentVariables = {
        HOME = "/Users/${username}";
        PATH = "/usr/local/bin:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      RunAtLoad = true;
      ProcessType = "Background";
      StandardOutPath = "/Users/${username}/Library/Logs/mana-hermes.log";
      StandardErrorPath = "/Users/${username}/Library/Logs/mana-hermes.log";
    };
  };

  # ── Zsh ───────────────────────────────────────────────────────
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    initContent = ''
      # Homebrew (Apple Silicon installs to /opt/homebrew). Nix manages most
      # packages, but brew-installed casks still need their prefix on PATH.
      if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
      fi

      # Mana is the sole public repo command. Its implementations live privately
      # under libexec/mana and are reached as `mana <command>`.
      # The official oMLX app maintains its CLI shim here.
      export PATH="$HOME/repo/mana/bin:$HOME/.omlx/bin:$HOME/.local/bin:$PATH"

      _mana() {
        local -a commands subcommands
        commands=(
          'version:show installed tool and application versions'
          'bootstrap:set up or reconcile the complete workstation'
          'rebuild:apply the current Nix configuration'
          'update:update Nix, Homebrew, and the stable oMLX app'
          'doctor:check oMLX and Hermes and optionally repair services'
          'services:review and control managed services and Apple containers'
          'omlx:install, update, and control the oMLX app/server'
          'hermes:control or chat with the Hermes container'
          'uninstall:remove one imperative component'
          'help:show command help'
        )
        if (( CURRENT == 2 )); then
          _describe 'mana command' commands
          return
        fi
        case "$words[2]" in
          help)
            _describe 'mana command' commands
            ;;
          hermes)
            subcommands=(chat up down restart rebuild status dashboard logs)
            _describe 'Hermes command' subcommands
            ;;
          omlx)
            subcommands=(status install upgrade start stop restart logs models key)
            _describe 'oMLX command' subcommands
            ;;
          services)
            if (( CURRENT == 3 )); then
              subcommands=(list status start stop restart logs)
              _describe 'service action' subcommands
            elif (( CURRENT == 4 )); then
              subcommands=(omlx hermes container 'container\:hermes-agent')
              _describe 'service (or container:<id>)' subcommands
            else
              _arguments '--yes[confirm runtime-wide interruption]'
            fi
            ;;
          uninstall)
            if (( CURRENT == 3 )); then
              subcommands=(omlx hermes container)
              _describe 'component' subcommands
            else
              _arguments '--purge[also delete component data]' \
                '--keep-models[preserve oMLX model weights]' \
                '--keep-config[preserve oMLX settings]' \
                '--yes[skip confirmation]' \
                '--dry-run[show actions without changing anything]'
            fi
            ;;
          doctor)
            _arguments '--fix[repair detected app, runtime, and container issues]' \
              '--yes[confirm disruptive repairs]'
            ;;
          update)
            _arguments '--no-flake[skip updating flake inputs]' \
              '--no-brew[skip the explicit Homebrew upgrade]'
            ;;
        esac
      }
      compdef _mana mana
    '';
    shellAliases = {
      # Modelops: cd bookmark only. Workflow commands are intentionally NOT aliased
      # — see modelops/README.md and run them yourself to learn the toolchain.
      modelops = "cd ~/repo/mana/modelops";
    };
  };

  # ── Starship prompt ──────────────────────────────────────────
  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      # Minimal preset — tweak to taste
      add_newline = false;
      format = "$directory$git_branch$git_status$character";

      character = {
        success_symbol = "[›](bold green)";
        error_symbol = "[›](bold red)";
      };

      directory = {
        truncation_length = 3;
        truncate_to_repo = true;
      };

      git_branch = {
        format = "[$branch]($style) ";
        style = "bold purple";
      };

      git_status = {
        format = "[$all_status$ahead_behind]($style) ";
        style = "bold red";
      };
    };
  };

  # ── Tmux ─────────────────────────────────────────────────────
  programs.tmux = {
    enable = true;
    terminal = "screen-256color";
    escapeTime = 10;
    historyLimit = 10000;
  };

  # ── GitHub CLI ───────────────────────────────────────────────
  programs.gh = {
    enable = true;
  };

  # ── SSH ──────────────────────────────────────────────────────
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        UseKeychain = "yes";
        AddKeysToAgent = "yes";
      };
    };
  };

  # ── Git ──────────────────────────────────────────────────────
  # User identity is intentionally not declared here — set it locally:
  #   GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.name  "Your Name"
  #   GIT_CONFIG_GLOBAL=~/.gitconfig git config --global user.email "you@example.com"
  # Why GIT_CONFIG_GLOBAL? home-manager owns ~/.config/git/config as a
  # read-only symlink into the nix store, so plain `git config --global`
  # fails with EACCES. Writing to ~/.gitconfig works — git merges both.
  programs.git = {
    enable = true;
    settings = {
      init.defaultBranch = "main";
      pull.rebase = true;
    };
  };

}
