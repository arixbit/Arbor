cask "arbor" do
  version "1.0.41"
  sha256 "6823d20ccbbe1ae5073871fb164dcc0912c30406089220953ad2556f4cb4fe8a"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
