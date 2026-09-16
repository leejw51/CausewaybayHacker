-- The poster, drawn and proved, under LÖVE with the key library.
--
-- Needs a graphics context and `libcwbh_ffi`, so this runs under `make test`
-- and is skipped headless. It is the LÖVE half of `e2e/poster.spec.ts`: a
-- program is signed with the fixture phrase, drawn at both sizes, written
-- through `io.open`, given its text chunks by the library, and read back
-- from the file on disk — chunks, label decoded from the pixels, signer
-- recovered — until the same `prove` the playground runs before it keeps a
-- poster says nothing is wrong. Then a doctored copy has to be called out.

local T = require("tests.framework")

return function()
  T.section("poster — drawn, written, and read back from the file")
  if not (love and love.graphics and love.graphics.newCanvas) then
    T.skip("poster render", "needs love.graphics; run `make test`")
    return
  end
  local wallet = require("src.wallet")
  local lib = wallet.load(os.getenv("CWBH_ROOT") or ".")
    or wallet.load("/Volumes/nvidia/vivid/CausewaybayHacker/love2d")
  if not lib then
    T.skip("poster render", "libcwbh_ffi is not built")
    return
  end
  local Poster = require("src.poster")
  local Reader = require("src.diskreader")
  require("src.assets").load()

  local PHRASE = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
  local SOURCE = 'fn main() {\n    let city = "Causeway Bay";\n    println!("héllo from {city}");\n}\n'
  local me = wallet.derive(lib, PHRASE, 0)
  local signed = wallet.sign(lib, PHRASE, 0, SOURCE)
  local function recover(message, signature)
    local r = wallet.recover(lib, message, signature)
    return r and r.address or nil
  end
  local function qr(text)
    return wallet.qr(lib, text).rows
  end
  local function too_dense(text)
    local r = wallet.qr(lib, text)
    return (not r) or r.size > Poster.QR_MAX_MODULES
  end
  local function keccak(text)
    return wallet.keccak(lib, text).digest:sub(3)
  end
  local input = {
    lang = "rust",
    name = "word tally",
    file = "main.rs",
    source = SOURCE,
    run = Poster.run_of(
      { outcome = "ok", compile_ms = 412, run_ms = 3, exit_code = 0 },
      { { stream = "stdout", text = "héllo from Causeway Bay" } }
    ),
    user = { name = "Ferris Wong", address = me.address },
    signature = signed.signature,
    at = os.time(),
    qr = qr,
    too_dense = too_dense,
    keccak_hex = keccak,
  }

  local dir = os.getenv("TMPDIR") or "/tmp"
  dir = dir:gsub("/$", "") .. "/cwbh-poster-test-" .. tostring(os.time())
  wallet.secure(lib, dir, true)

  T.case("the small square holds a short program whole, with a scannable label", function()
    local r = Poster.make(input)
    T.eq(r.size, Poster.SIZE)
    T.eq(r.hidden, 0)
    T.ok(r.qr_cell >= Poster.QR_MIN_CELL)
    T.eq(r.hashed, false)
    r.canvas:release()
  end)

  T.case("a long program goes to the big square, and its label is a hash", function()
    local long = {}
    for i = 1, 70 do
      long[i] = ("fn step_%d(x: u32) -> u32 { x.wrapping_mul(%d) ^ %d }"):format(i, i + 3, i * 7)
    end
    local big = Poster.make({
      lang = "rust",
      name = "seventy",
      file = "main.rs",
      source = table.concat(long, "\n") .. "\n",
      run = nil,
      user = input.user,
      signature = nil,
      at = os.time(),
      qr = qr,
      too_dense = too_dense,
      keccak_hex = keccak,
    })
    T.eq(big.size, Poster.SIZE_LARGE)
    T.eq(big.hashed, true)
    T.ok(Poster.parse_payload(big.payload).body:sub(1, 10) == "keccak256:")
    big.canvas:release()
  end)

  local path = dir .. "/" .. Poster.file_name("word tally", os.time())
  T.case("written, stamped with its proof, and read back verified from disk", function()
    local r = Poster.make(input)
    T.ok(Poster.write_png(r.canvas, path), "the PNG is on disk")
    r.canvas:release()
    local ok = wallet.png_text(lib, path, {
      Title = "word tally",
      Source = SOURCE,
      Lang = "rust",
      Signer = me.address,
      Signature = signed.signature,
    })
    T.ok(ok, "the chunks went in")
    local read = wallet.disk_read(lib, path, true)
    T.ok(read, "the library reads the file")
    T.eq(read.chunks.Source, SOURCE)
    T.ok(read.label ~= nil, "the label decodes off the pixels")
    T.eq(read.label, r.payload, "and says exactly what was drawn")
    T.eq(Reader.prove(read, read.label, SOURCE, me.address, signed.signature, recover, r.payload), nil)
    -- As the reader would take it, chunks first.
    local disk = Reader.from_read(wallet.disk_read(lib, path), recover)
    T.eq(disk.verdict, "verified")
    T.eq(disk.via, "chunks")
    T.eq(disk.title, "word tally")
    T.eq(disk.source, SOURCE)
    -- And with the chunks gone — the JPEG — the label alone still convicts.
    local jpg = path:gsub("%.png$", ".jpg")
    T.ok(wallet.jpeg(lib, path, jpg, 90), "a JPEG beside it")
    local from_jpeg = Reader.from_read(wallet.disk_read(lib, jpg), recover)
    T.ok(from_jpeg, "the JPEG has a readable label")
    T.eq(from_jpeg.via, "label")
    T.eq(from_jpeg.verdict, "verified")
    T.eq(from_jpeg.source, SOURCE)
  end)

  T.case("a doctored program is forged, and a stranger's address is named", function()
    local read = wallet.disk_read(lib, path)
    local doctored = {
      chunks = {
        Source = SOURCE .. "// mine now\n",
        Signer = read.chunks.Signer,
        Signature = read.chunks.Signature,
        Lang = "rust",
      },
    }
    T.eq(Reader.from_read(doctored, recover).verdict, "forged")
    T.eq(
      Reader.prove(read, nil, SOURCE, "0x0000000000000000000000000000000000000000", signed.signature, recover, ""),
      "signature"
    )
  end)

  os.remove(path)
  os.remove((path:gsub("%.png$", ".jpg")))
  os.remove(dir)
end
