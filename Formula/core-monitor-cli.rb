class CoreMonitorCli < Formula
  desc "macOS system monitor and fan control CLI backed by an SMJobBless helper"
  homepage "https://github.com/offyotto-sl3/Core-Monitor-CLI"
  url "https://github.com/offyotto-sl3/Core-Monitor-CLI/releases/download/v0.1.0/core-monitor-cli-0.1.0.tar.gz"
  sha256 "1c9ece00d4e2c22c07ea4e502e8b632e7c69822c196163a528b0a43dfbace067"
  license "MIT"

  depends_on macos: :ventura

  def install
    bin.install "bin/core-monitor"
    libexec.install "libexec/CoreMonitorBlessHost.app"
  end

  def caveats
    <<~EOS
      Core Monitor CLI installs a signed SMJobBless helper on first use.

      The first command that touches SMC state will prompt for administrator approval:
        core-monitor helper install

      Homebrew intentionally installs the prebuilt, signed artifacts. A source build
      cannot satisfy SMJobBless without the vendor's signing identity.
    EOS
  end

  test do
    output = shell_output("#{bin}/core-monitor helper status")
    assert_match "helper label: ventaphobia.smc-helper", output
  end
end
