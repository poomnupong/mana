{ pkgs, username, ... }:

{
  # Nix management handled by Determinate Systems installer
  nix.enable = false;
  nixpkgs.config.allowUnfree = true;

  # System-level packages (available to all users)
  environment.systemPackages = [ ];
  environment.etc."mana/home".text = "/Users/${username}\n";

  # Expose nix profile paths to GUI apps
  environment.etc."paths.d/nix".text = ''
    /etc/profiles/per-user/${username}/bin
    /run/current-system/sw/bin
    /nix/var/nix/profiles/default/bin
  '';

  # ── oMLX inference server ──────────────────────────────────────
  # The official prebuilt macOS app is installed by mana bootstrap and owns
  # the server lifecycle. Keeping it outside Homebrew avoids source builds
  # whose Python downloads may be blocked on managed networks.

  # Homebrew inventory is declarative; mana update owns version upgrades.
  homebrew = {
    enable = true;
    onActivation = {
      autoUpdate = false;
      upgrade    = false;
      cleanup    = "zap";
      # Homebrew >= 5.1 refuses `brew bundle --cleanup` unless one of
      # --force / --force-cleanup / $HOMEBREW_ASK is also passed (it now
      # asks for confirmation before removing unlisted formulae/casks).
      # nix-darwin runs activation non-interactively, so pass --force to
      # auto-confirm the cleanup and avoid:
      #   Error: Invalid usage: `brew bundle install --cleanup` requires
      #   `--force`, `--force-cleanup` or `$HOMEBREW_ASK`.
      extraFlags = [ "--force" ];
    };
    casks = [
      "iina"
      "iterm2"
      "visual-studio-code"
      "copilot-cli"
      "github-copilot-app"
      "lm-studio"
      "appcleaner"
      "google-gemini"
    ];
    brews = [ ];
  };

  # Required: declare the primary user for Home Manager integration
  users.users.${username} = {
    name = username;
    home = "/Users/${username}";
  };

  system.primaryUser = username;

  # Used for backwards compatibility
  system.stateVersion = 5;
}
