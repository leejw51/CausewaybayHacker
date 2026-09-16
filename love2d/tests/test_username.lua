-- The deterministic display name, against the published vectors.
--
-- Headless: `src/username.lua`'s arithmetic is split from the hashing for
-- exactly this reason. The keccak comes from the key library, which is a
-- `.dylib` a headless run has no reason to load, so the digests below are
-- written out and the part this file tests is the part that turns a digest
-- into a name.
--
-- The four names are the ones `backend/core/src/username.rs` and
-- `frontend/tests/username.test.ts` assert, and the digests are
-- keccak256(utf8(lowercase(address))) for the four addresses those files name.
-- Three implementations of one algorithm agree here or they do not agree
-- anywhere: each client shows a name before there is an account to ask about,
-- so a client that drifted would promise a name the server then disagreed
-- with.

local T = require("tests.framework")
local Username = require("src.username")

--- `{ address, keccak256 of the lowercased address, the name it must produce }`
local VECTORS = {
  {
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    "0x4171dea24ee6cef501949ab6e74eba7924572146d27f2f712aeec3816c71c167",
    "OmegaMustang0198",
  },
  {
    "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "0x5c965f21987602c24e15f9916cbbfcc7c4aee0894df8d669725ee5ae5df25f03",
    "AmberLion9030",
  },
  {
    "0x9858effd232b4033e47d90003d41ec34ecaeda94",
    "0xe8b6e0ae59002b4eb2e83362498004e493971cbc675b6da1b2775df5e7d0af89",
    "AmberEnchanter2784",
  },
  {
    "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf",
    "0x56a6eb3142b2cdc8d47682a4ba1023997d2cd75880b0ce50d5a0b2b2aa9928c7",
    "AmberRunner7074",
  },
}

return function()
  T.section("username — the name a wallet wears until somebody chooses one")

  T.case("the word lists are the reference lists, at the reference lengths", function()
    -- The lengths are the modulus, so they are part of the contract rather
    -- than a fact about the tables: a list that grew by one word would rename
    -- roughly every account in the game.
    T.eq(#Username.ADJECTIVES, 152)
    T.eq(#Username.NOUNS, 156)
    -- The first of each, because order is protocol and a list that got sorted
    -- would still have the right length.
    T.eq(Username.ADJECTIVES[1], "Epic")
    T.eq(Username.NOUNS[1], "Wolf")
  end)

  T.case("names match the server and the web client", function()
    for _, v in ipairs(VECTORS) do
      T.eq(Username.from_digest(v[2]), v[3], "diverged for " .. v[1])
    end
  end)

  T.case("the three reads come out of the digest in the documented order", function()
    -- All-zero digest: index 0 of each list, and a suffix of 0000. It pins
    -- which bytes are read as much as the vectors do, and it is readable.
    T.eq(Username.from_digest("0x" .. string.rep("0", 64)), "EpicWolf0000")
  end)

  T.case("the 0x prefix is optional", function()
    local bare = string.rep("0", 64)
    T.eq(Username.from_digest(bare), Username.from_digest("0x" .. bare))
  end)

  T.case("every name fits what the server's name column will take", function()
    -- 48 characters is where `users.name` truncates, and a name the store cut
    -- in half would be a different name on screen than in the column.
    for i = 0, 255 do
      local digest = ("0x%064x"):format(i * 2654435761 % 0xFFFFFFFF)
      local name = Username.from_digest(digest)
      T.ok(#name <= 48, name .. " is too long")
      T.ok(name:match("^%a+%d%d%d%d$") ~= nil, name .. " is not Adjective/Noun/4 digits")
    end
  end)
end
