# Homebrew formula for the bridge (rendered by packaging/render.sh on each release).
#   brew install jairofernandez/kubiverse/k8s-bridge
class K8sBridge < Formula
  desc "Bridge between Kubiverse (a voxel game) and your Kubernetes cluster"
  homepage "https://github.com/jairoFernandez/kubiverse"
  version "@VERSION@"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/k8s-bridge-darwin-arm64"
      sha256 "@SHA_DARWIN_ARM64@"
    end
    on_intel do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/k8s-bridge-darwin-amd64"
      sha256 "@SHA_DARWIN_AMD64@"
    end
  end
  on_linux do
    on_arm do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/k8s-bridge-linux-arm64"
      sha256 "@SHA_LINUX_ARM64@"
    end
    on_intel do
      url "https://github.com/jairoFernandez/kubiverse/releases/download/v@VERSION@/k8s-bridge-linux-amd64"
      sha256 "@SHA_LINUX_AMD64@"
    end
  end

  depends_on "kubectl" => :recommended

  def install
    bin.install Dir["k8s-bridge-*"].first => "k8s-bridge"
  end

  def caveats
    <<~EOS
      Start it and open the game in your browser (it comes inside):
        k8s-bridge
        open http://127.0.0.1:8088
    EOS
  end

  test do
    assert_match "-addr", shell_output("#{bin}/k8s-bridge --help 2>&1", 2)
  end
end
