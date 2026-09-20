#!/usr/bin/env python3
"""The content gate's own rules, checked without a compiler.

`verify_pack.py` compiles every quest, which is the slow, honest half. This
is the fast half: the structural rules on hand-written fixtures, so a rule
that stops firing is caught in a second rather than never. Run with
`python3 -m unittest tests/content/test_verify_pack.py`.
"""
import pathlib, sys, tomllib, unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import verify_pack as vp  # noqa: E402

FIX = HERE / "invalid-packs"


def structural(name, **edits):
    path = FIX / name
    pack = tomllib.loads(path.read_text())
    for key, value in edits.items():
        pack["quest"][0][key] = value
    # the file-path rule is about where a real pack sits, not a fixture
    fake = HERE.parent.parent / "content" / pack["land"] / f"{pack['category']}.toml"
    vocab, _ = vp.load_vocab()
    errs, _ = vp.structural(pack, fake, vocab)
    return errs


class AddedLines(unittest.TestCase):
    def test_counts_only_what_the_starter_lacks(self):
        starter = "fn main() {\n    // FILL\n    let x = 1;\n}\n"
        solution = "fn main() {\n    let x = 1;\n    println!(\"{}\", x);\n}\n"
        self.assertEqual(vp.added_lines(starter, solution), ['println!("{}", x);'])

    def test_a_rust_deref_line_is_not_a_comment(self):
        self.assertEqual(vp.added_lines("", "*count.entry(k).or_insert(0) += 1;"),
                         ["*count.entry(k).or_insert(0) += 1;"])
        self.assertEqual(vp.added_lines("", "* a block comment line"), [])


class QuizRules(unittest.TestCase):
    def test_the_answer_may_not_be_given_away(self):
        errs = structural("verybasic-answer-given-away.toml")
        self.assertTrue(any("given away" in e for e in errs), errs)

    def test_a_clean_quiz_passes_the_structural_rules(self):
        brief = "Which line prints the greeting?\n\n```\ninput:\noutput: hello, causewaybay\n```\n"
        errs = structural("verybasic-answer-given-away.toml", brief=brief)
        self.assertEqual([e for e in errs if "map:" not in e], [], errs)

    def test_four_choices_and_an_answer_in_range(self):
        brief = "Which line?\n\n```\ninput:\noutput: hello, causewaybay\n```\n"
        errs = structural("verybasic-answer-given-away.toml", brief=brief,
                          quiz={"choices": ["a", "b", "c"], "answer": 5})
        self.assertTrue(any("3 choices" in e for e in errs), errs)
        self.assertTrue(any("out of range" in e for e in errs), errs)

    def test_the_right_choice_must_be_the_typed_line(self):
        brief = "Which line?\n\n```\ninput:\noutput: hello, causewaybay\n```\n"
        errs = structural("verybasic-answer-given-away.toml", brief=brief,
                          quiz={"choices": ["a", "b", "c", "d"], "answer": 0})
        self.assertTrue(any("is not the line the solution adds" in e for e in errs), errs)

    def test_only_verybasic_carries_a_quiz(self):
        pack = tomllib.loads((FIX / "basic-with-time-limit.toml").read_text())
        q = pack["quest"][0]
        del q["time_limit_s"]
        q["concepts"] = ["io", "strings"]
        q["quiz"] = {"choices": ["a", "b", "c", "d"], "answer": 0}
        fake = HERE.parent.parent / "content" / "rust" / "basic.toml"
        vocab, _ = vp.load_vocab()
        errs, _ = vp.structural(pack, fake, vocab)
        self.assertTrue(any("only verybasic" in e for e in errs), errs)


class ShortnessGate(unittest.TestCase):
    def test_basic_allows_four_lines_and_verybasic_one(self):
        self.assertEqual(vp.MAX_ADDED["basic"], 4)
        self.assertEqual(vp.MAX_ADDED["verybasic"], 1)

    def test_the_too_long_fixture_is_refused(self):
        errs = structural("basic-too-long.toml")
        self.assertTrue(any("adds 11 lines" in e for e in errs), errs)


if __name__ == "__main__":
    unittest.main()
