# Homebrew cask for the native macOS game (rendered by packaging/render.sh).
#   brew install --cask jairofernandez/kubiverse/kubiverse
cask "kubiverse" do
  version "@VERSION@"
  sha256 "@SHA_MACOS_APP@"

  url "https://github.com/jairoFernandez/kubiverse/releases/download/v#{version}/kubiverse-macos.zip"
  name "Kubiverse"
  desc "Your Kubernetes cluster as a voxel world"
  homepage "https://github.com/jairoFernandez/kubiverse"

  depends_on formula: "jairofernandez/kubiverse/k8s-bridge"

  app "Kubiverse.app"

  zap trash: "~/Library/Application Support/Godot/app_userdata/Kubiverse"
end
