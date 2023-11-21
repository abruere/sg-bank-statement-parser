# sg-bank-statement-parser (2019)

Tool to convert Société Générale PDF bank statements to CSV files before feeding them into an ERP.

## Dependencies

- [pdftotext](https://www.xpdfreader.com/about.html)
- Ghostscript

Make sure `csv-sg-bank-statement` and `bankpdf2text`scripts are executable and run:

`csv-sg-bank-statement <bankStatementsNames*.pdf>`

The output should look like:

```
bankStatement_201806.pdf ==> bankStatement_512001_201806.csv done (37 lines).
bankStatement_201807.pdf ==> bankStatement_512001_201807.csv done (25 lines).
```

**Warning**: this is specific to this bank and my company needs at the time, when no appropriate data feed was available.

I hope it can help.
