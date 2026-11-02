cask "arbor" do
  version "1.0.33"
  sha256 "5ab11b1f6e8077f27ff57585f14907f1a675b08fca49badbae46810299f526e3"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
