# Homebrew formula for the bridge (rendered by packaging/render.sh on each release).
#   brew install jairofernandez/kubiverse/kubiverse-bridge
# (It used to be called k8s-bridge: formula_renames.json moves old installs.)
class KubiverseBridge < Formula
  desc "Bridge between Kubiverse (a voxel game) and your Kubernetes cluster"
  homepage "https://github.com/jairoFernandez/kubiverse"
  version "@VERSION@"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/kubiverse-bridge-darwin-arm64"
      sha256 "@SHA_DARWIN_ARM64@"
    end
    on_intel do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/kubiverse-bridge-darwin-amd64"
      sha256 "@SHA_DARWIN_AMD64@"
    end
  end
  on_linux do
    on_arm do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/kubiverse-bridge-linux-arm64"
      sha256 "@SHA_LINUX_ARM64@"
    end
    on_intel do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/kubiverse-bridge-linux-amd64"
      sha256 "@SHA_LINUX_AMD64@"
    end
  end

  depends_on "kubectl" => :recommended

  def install
    bin.install Dir["kubiverse-bridge-*"].first => "kubiverse-bridge"
    # The old command keeps working for a while.
    bin.install_symlink "kubiverse-bridge" => "k8s-bridge"
  end

  def caveats
    <<~EOS
      Start it and open the game in your browser (it comes inside):
        kubiverse-bridge
        open http://127.0.0.1:8088
    EOS
  end

  test do
    assert_match "-addr", shell_output("#{bin}/kubiverse-bridge --help 2>&1", 2)
  end
end
