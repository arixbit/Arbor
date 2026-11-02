cask "arbor" do
  version "1.0.30"
  sha256 "6fd25eee8bc5f86996701a1228bd338d8ba8d11df04c1f2ef2dd827ff4878c24"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
