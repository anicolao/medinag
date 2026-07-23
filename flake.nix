{
  description = "MediNag (`medinag`) development environment with git, gh, nodejs, and tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            git
            gh
            nodejs_22
            firebase-tools
            jq
            curl
          ];

          shellHook = ''
            echo "Entering MediNag development environment..."
            echo "Available tools: git $(git --version | awk '{print $3}'), gh $(gh --version | head -n1 | awk '{print $3}'), node $(node --version)"
            echo "Run 'gh auth login' to authenticate with GitHub."
          '';
        };
      }
    );
}
