cask "arbor" do
  version "1.0.18"
  sha256 "5b3697ecb6bec8b497249dedbaccae25285755917b1ac4cc131559410a46dcad"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
