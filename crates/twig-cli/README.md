# twig-doc-cli

The `twig` command-line tool: parse, query, edit, and losslessly round-trip
Djot, Markdown (CommonMark, GFM and Twig's default flavour), HTML, XML/SVG and
AsciiDoc documents. It is a thin layer over the
[`twig-doc`](https://crates.io/crates/twig-doc) core, with every language
crate twig ships registered.

    cargo install twig-doc-cli

```console
$ twig convert doc.dj                     # render HTML
$ twig convert -o markdown doc.dj         # serialize into another format
$ twig convert -o ast doc.md              # dump the AST as JSON
$ twig query doc.md 'heading[level=2]'    # list matching nodes and their paths
$ twig edit doc.md --replace 'heading("Status")' '## Done'
$ twig filter notes.md --directives --drop 'directive[name=vis]' --keep 'directive[class~=public]' --unwrap
$ twig lang list                          # compiled formats and runtime languages
```

`twig --help` and `twig <command> --help` describe every option.

Licensed under either of Apache-2.0 or MIT, at your option.
