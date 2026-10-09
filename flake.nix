{
  description = "Declarative macOS dev environment for the Hermes agent (Nix + nix-darwin + Home Manager)";

  inputs = {
    nixpkgs.url = "git+https://github.com/NixOS/nixpkgs?ref=nixpkgs-unstable&shallow=1";

    nix-darwin = {
      url = "git+https://github.com/LnL7/nix-darwin?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "git+https://github.com/nix-community/home-manager?shallow=1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix-darwin, home-manager, ... }: let
    system = "aarch64-darwin";

    # ── Per-machine identity ─────────────────────────────────────
    # Personalization lives in ./local.nix (gitignored), so this file
    # stays clean for upstream pulls. `mana bootstrap` generates local.nix
    # on first run from `id -un` and `scutil --get LocalHostName`. To
    # override manually, create ./local.nix with:
    #   { username = "jane"; hostname = "jane-mbp"; }
    # then use mana bootstrap/mana update to rebuild.
    #
    # NOTE: lifecycle scripts build a temporary source from tracked files plus
    # local.nix. Ignored secrets stay out of Nix and the Git index stays clean.
    defaults = { username = "your-username"; hostname = "your-hostname"; };
    local    = if builtins.pathExists ./local.nix then import ./local.nix else {};
    cfg      = defaults // local;
    inherit (cfg) username hostname;
  in {
    # Empty Home Manager activation removes Mana's managed files/packages before
    # the nix-darwin uninstaller runs or a pre-Mana system is reactivated.
    darwinConfigurations."${hostname}-uninstall" = nix-darwin.lib.darwinSystem {
      inherit system;
      modules = [
        home-manager.darwinModules.home-manager
        {
          nix.enable = false;
          system.primaryUser = username;
          system.stateVersion = 5;
          users.users.${username}.home = "/Users/${username}";
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.${username} = {
            home.username = username;
            home.homeDirectory = "/Users/${username}";
            home.stateVersion = "25.05";
            manual.manpages.enable = false;
          };
        }
      ];
    };
    darwinConfigurations.${hostname} = nix-darwin.lib.darwinSystem {
      inherit system;
      specialArgs = { inherit username; };
      modules = [
        ./darwin.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.backupFileExtension = "hm-backup";
          home-manager.extraSpecialArgs = { inherit username; };
          home-manager.users.${username} = import ./home.nix;
        }
      ];
    };
  };
}
