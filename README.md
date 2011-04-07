# Usage


    ./tmp.rb example.txt 


outputs: 


    SyntaxNode+Document0 offset=0, "...ome, other, phrase\"\n" (word_or_phrase):
      SyntaxNode+WordOrPhrase0 offset=0, "..., phrase, here\"~100\n" (DELIMITER):
        SyntaxNode+QuotedPhrase2 offset=0, "...e, phrase, here\"~100" (DQUOTE1,DQUOTE2):
          SyntaxNode offset=0, "\""
          SyntaxNode offset=1, "some, phrase, here":
            SyntaxNode+QuotedPhrase0 offset=1, "s":
              SyntaxNode offset=1, ""
              SyntaxNode offset=1, "s"
            SyntaxNode+QuotedPhrase0 offset=2, "o":
            
            ...