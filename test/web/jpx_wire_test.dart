@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/unseal.dart';

import '../tests/pdf/pdf_fixture_builder.dart';

// The committed gray53-lossless-lrcp and rgb53-lossless-rct codestreams
// (test/resources/pdf/jpeg2000/, SHA-256 digests in MANIFEST.md),
// inlined so the browser suite needs no HTTP fixtures.
final Uint8List grayJ2k = base64Decode(
  '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',
);

final Uint8List rgbJ2k = base64Decode(
  '/0//UQAvAAAAAABAAAAAQAAAAAAAAAAAAAAAQAAAAEAAAAAAAAAAAAADBwEBBwEBBwEB/1IA'
  'DAAAAAEBBAQEAAH/XAAQQEBISFBISFBISFBISFD/ZAAlAAFDcmVhdGVkIGJ5IE9wZW5KUEVH'
  'IHZlcnNpb24gMi41LjT/kAAKAAAAACkTAAH/k8fUHBFgQgwW6IxIQaQf0su7wfIKD+y94E9I'
  'sATt38D4Sg7MRrg/Wm/73H/B846B8guB844iCEkAZur3ACsBVdiSbxSZ54vp0fvf2ErnA5eL'
  '67UypATZ8ivi1qfA+QZA+QZA+cYAF0tSxYEC/pcALlYfEXzObWvAISAJB2gHAh4BFFZkfm00'
  'lnjPwfONgfIMgfOOF1Mh8DTWoB2BMVAGzxOERxo1N2cQaDNfPxHcuFmAn9u9/ace48CHw+oz'
  'g+dTB9RsMPft4OaiwGLuuGfzaqzjvk19sfrGhmNhaRtxSbiYCdVxUzxorFCOx2zXtnOFsLyF'
  'yflPEhoNdi99nM97iQSPudVhvoOVEzd+N8yltVj3lLEKx8/u7iP7RCAaO7wrIpU8EGD8ollf'
  'BvRjvY7R1EVWgRdgUanQtCO9SQ3MiPXx/BB3g2wmIZXJxAteY5Ek+yTbUj/B87KH1GsPtOAC'
  'v3Luj5vZLm1mYhQ7rfqHnlFr9+LPv3Jn9RxrT0jydMbQObvkUGRKHHKTzRATzsgoVhyARkET'
  'KUNthNp5l8DTiJifend0MYnk/w55liBMsjR/zFf4fftyO7wbB8f4b7RIzvURb7OqNgIaXua1'
  'gNaQbm+w+O7vPZx4ouACLuXQnOURGIerm3gUklXOF9cPiYDtl1cnjFNIzblEsAk57n/D6jaH'
  '1GsH1HIe63hT0iXiHHTpDIvcdwZJNHPdQ0yX5oRhP5XET4quyft2QcHEAkshctOU1fv9VvbZ'
  '+4v1vH9GB4tFPD5szEhj7kssTfSaxzALyiZON/VXmQ6dcVaa71F1cbBO6XAyNNnY7/Kyxift'
  'Hfj6nxi7bxaoqt76yb6hyiRlNGjSheaEcIl7gy6IwJJV56VIA9dZGrMtQlLT69P0a8n2eC+6'
  '9HhDdakiv8PqsCD59aQfVaYvDOFocDMU14mF/qjRlu5qKeni5cVkihR+dHTN49IBFoKmcYrM'
  'JIqyJ/o0nf1LfJfrGWtCkvTaAo4BCbV/RwgkUA0pwZXW+tdkCvJluTJ8hixE4PJXxvl12hDI'
  'E7crO5aA1jB7Tl9eVPnZ9v8Oa1XsWG3oyvXrBWiGChivNUHCD++95JODqcgHU7kK1doFg6RO'
  'O93hwGgoz4gE56iKqBZSF0/dY6dLz/laINDOfpfSleBqWPWNOqS0uUXn0o3u9H8PT6FWglCG'
  '1CBuMlaC00E4I03wBRzPR7RswnXnfGzO1UUFJFLD3tdUaxMfL8l8Z5ogAcOb4aADsrYo7x7A'
  '71xEP3ZrVciC6OUUIs7yWsCfxud+nZu2bYY06GrmvOhUq1eTG0Soc12KelecCywNXUUBGoNu'
  'fG7SoHXI8bqEkd9ytoGu3X+oYatdpYydOvnOFppG/NObmbhkWWHNEs6INzOst9TO9o8lqcqZ'
  '3CKQcpBHIcBBLH8ahpDu1dj/GSNKZ3z6lPCAD54/LGk422W8VA7Rxk5Oye6a0Nv9QQaO2Iul'
  'iJ4JILgt0jrL8sqqt1BEcmg8ThroyrlsWv7QecPH7JOGkQq8b+xOVKiUOGcSfgecrP2z0cE7'
  'A96IAIrolGKiLEFOApxTYpn0saICzYBAO/XAUX1yjlHiS2x+Gmqqj11RJCFw9rNXjt9EUGR+'
  '1WYJR5dSklK+ZC2Yt2GIHXnt2hLpXSFHkpBMLG+3z/fd3xSttnENBXlPrhs3+cLexY5j1y/i'
  'shr+mS/Kw+q24fVbMPtvYBqGgUDUDSFt0GEpbVpZE5xKtMN2227Md3uczTXAQRfQdvSD2l/t'
  '2m591IdQ/dRs5zlsrM5BRVWq4iz9HHnhyIliRoKa8ibq7jMAfa9EsrKJKAfgjLzstcGv6d2J'
  'l71zV/v40ZT1kESe3mkLtBV7t3zcXWc+EpF2kSj2hx0E78WwnUIbSAGkgEy+3x+BH/29mudl'
  'o9X3BJVLAPW7Xt7ZwCTaEPRLXeskqS2zWd1GrfuHN711rgZdQAsEqRCnKeX67g4GaeJNZBVh'
  'mphW7RhU1rePk+ulHKoqDXhBlAnlRZYcj0HHTFSaVbbYDxYKyoVb3wSe9txbGvMm7VKgmHDg'
  '6z3pV12M3sg8okdaCRsf6yywxUdmf31etReN8qPNY6ybH8Ragd4Ts2IA1cSAh3ypapBA+b0H'
  'wqAtX/QrtXvemti4PPu6JTbDd7VYSylybP5He9oHszhQbF+Aci+6rghbO89ROBlSUPonNyvZ'
  'Cgso3MMSouP7qSRN8e8HB+cYnjWa0myVYDWP55KcBdU0t/96Pfe9JEpkbve+zMFBganIBpWq'
  'v5tqqHI9kt0L7+JGxirGkMWN4p8XScEGkIFuIbtFTDEA4yIBZHn7/RdVX8BsGjnr39u294R/'
  '0UATuePzx/3otBrC1ArxEnrbx9G0ql4qTK98ZVqSCDCn+7brVVrrZeqiJP2CYQd+iUjgwBRq'
  'weuwC4RQYxT5AkOCICONkVbWh/oRtO/4B6+mHkCLEPFVzFBVx8cGTXCX1xS1u/D6QZlaaqBJ'
  'LWUCM5ZfeKU03B9kyGVS6imwHj42kyb0UmOAyMHlkFydxLbwLIMTvX0BtJ7ZVVG0EKvk6iVw'
  'aoN/FuEqvrUAQ3sgko/7gTXwnD4VxnAvocjcD9x0ORykpKmiv2Jvu3V8naov7sHZgLnD6rah'
  '9VrQ+2+QEge+Y10+eqZw6VuKr7cJsA5ffe5TPa3K4yWLwax09iIPDbyqTxqBjNFH7OWXRwcG'
  'pIETkSKF4/iYyz/8TSksaitSoxyV0w2MK4lZqhoYAfenzTTDX/99b2IPHqtMs3xZZjDA1v9F'
  'wpIgWeskSeQF8+cPi6WgNVM7awTknw6oDQEFEjo2Fi6s9OFKS8VbF7FftvltW9Qlf3VCCf9Z'
  'wSIK+iWMwU4a/CL4ZpZrhSOvZzxlRitdAXsE5nkZWG/85S6dOTUOYg7p7TLcqQCnRnLL/eJX'
  'NRcH5pXn2T8Yp3iDFWe9mfPtCXiZCNRZu6uksUcnUae3ygIarP2piFwThaxQJL5D8jk2edGf'
  '3dKifsQxprIpUmdMrtIikGKwEYkJ0eYwfUb+AnGyUm0YEqdJ1UFd6/YtzqRTXBpM6ZXQ4zTt'
  'DseFzPn/aPmxwIbsc3zLNzPXIvLBsGKdF0bsaPrM/QYA+Y2MPR5J7MWPJCMk7E/SH0GmDP8g'
  '4beHYHNZDqZiF7BWZ9bEBznSzC/ZLR6kDsUQuvKXwTzw0fVLplSNjym01dKa2FbGQqFzqybK'
  'pHlqZTR/HIoUC+4Sg8tZ9PDTSKH8laY7D+smZM6ToSiCpbcdx1w0KAy2sQNJ9gxUiyRdqQQ7'
  '1G3OT1gcHeam+FFaXxPP6JWP+dlSHRNnxKkAO0R3a3dPyhpOcOV67iIG3FmOVR81LaqCMGq5'
  'F31MM0Se6Qjood8pX817uIBr3Rq7Au63AmfpJxue7uvlWFp6xxsqv1vjKfVbxG9Dgyq5vhLI'
  'kaOjtUD4kSIwTt3rzitlgFkm3GwGF3MoWE9yDNU0fptrI4SJrZHNc1AWQ0e8Q1MZdrP8hm8z'
  'tmFzKfqrnEyXLbmq8jvqocNGbl8ALGbMpEUHWs2wEnpB4RYklkx/w+rsEh9XXrB9XZmAB0rY'
  'ROseomqH2pNXvhuLnoqHanBeNe8MAjkzQaH8t2iS/gRFq6QMRGSqv/zUBBCpHBGVCs7s+esM'
  'JX1Z+0uVH07dX8iegwhomsKCYeZ5Xd9IwhQvj8Ys0NfJTgD9riagERoj7LDRAIKD5tX1/Kep'
  'mAS5ho9A9JrimMMXRPCdrWJCaiY4U6HjrNDXQhXS6ulsNSS+LEPUrfr8HX5z5W5kHh52o+nx'
  'JLqfEdETUk3uJ5JlXe/aI7QhJOIqG9aSKf632CEWHcKF/14GyldBKtFfJ8qdf5trBLJxIrYb'
  'q4O7i3awQqZl3rXl5fVkaRJ+d1Eaw4doVIlr2uomn+K6jg19mPLPUtYYzO/rqHinbNl0cGFX'
  '9nHsPqm7cPhcyoC+eTFNJX7+n1rvyTEtL0iwKYpntrcGkjPVt2Tgyr+Gv1Pzr/RkZYbV2akj'
  'HCRvHnuh38foieO8betG0J2KtoKEDZW69b4TjrBnkuFwT7839xjVg5evOLEZUdZkYBHWLZe5'
  'qDWSM58pxyId3Lc4rNwUDL5mQ/Eo36PP/fSPcO56jG82UVSnRsL4Zq9bPKJwuYekJalzBqtO'
  '4tBMOYgU1JO/LxIN0o9I++QrgcHcbvfdJCGtfTh3x46dSycFXRTmo16ShFV7JwPFGRGOGY19'
  'WloGXQ1aoc2tVbBuoCy9Ia80hiNXpkt0/yrMOkIisTkaC87kkTsr6JDYZGYXetdOSnzPg8cp'
  'KlxPO3oYMMLtcbKRc1m8SA3AZan9q/j67W3E4EmKXPvmcKzkQxr1Sex79jSa+4llGkQ6fuyQ'
  'SN22uvPlqkuU/sq7fZro1XGmY1ZFG7MU7x4Z2fG/xWOq5ZKRBwyxWHL/NDsG1T5Xbqb/TTPk'
  'wYmN/yexIGmB0RA8Y6lPE3gksBqb0lTeEGSa5e1sbzxNg4bzkUHmaVH0rLUKabxzKjwYFYO0'
  'EVigStUziGXlFb0l88vjzE2Mvzx1+fqh7OipnynPicRl860ckIDUisU1nrIW+b4S8tKEEcCm'
  'KUSd1nf13cpqTrII78Asb2iTqnPh9V8M+Uy0M8IQoB0ONi6FDJ7PgXiW7Kriu0NXVkeb7W6y'
  '1A1ju93GZzQ5Qk7ddOMzmipPGu45Ke0WdqqXk984pCHHfBZTODpCfGBzAeGNgBfLy4vIIjNV'
  'l2/zvj/0eqzLe0nhYXn2q1MXpBeZjAhe6pDxDVJ1iLfWBMw8tD/Vu9vJ1mQflunyQGNsK8w1'
  'nYG6+beBSKB9C1PUSfbWepyDqTaxSnNKXTrfRDfGhIgqSZoawTvPTaAm4k4+hPuxCc2MofOo'
  't2BwCccCEP3mNEkCNCat1tCFs6IAd4+0mcpFsDr4iM3tDqbRphyu88snTnMffIaRPbucg0mn'
  'sLbOFEkQXeklVayCXRegfQEu4MMVMsHZNXLdYISBWi8ZNq1iyQG/27LMJ1nM9SKy62ANSQ1F'
  'u5FgpTgAyCjQCkDpjOpfWrK+JsWKYTGZ7WCByjvJKdmsBqPMIGkOliGq35S0wyHMtfm6yHeJ'
  '3mBmoUQF+XYgVQNajA/iYGFfiFA2BiAa8c6Wx9tM3Y6hiHa3j4bQuiEitKSJlWLyElWoGAef'
  'Aq6/77cjqOR1YtxpyqdMCI8xe0FR/R4AuX9JukRWfTWwT7+d3PGgpNxJaaatiNRHfGCz8kYj'
  'vIGnGezNrEsJlAnLJqlGeeieL2ZHPdW1aF9oGnwMN4eD7YtOMUZwDEVOkZ5Bm2HaHCsYLBlA'
  'uYA4tPClfxGOLAJQxq0GqXwITpxZrYHoFjmYnt6BGAxGw0pG60NX9t1Sws1SdvopQRKyGlw2'
  'oenghDFeSQ9RKnGr6MaoHaUL5I2a9GK/UFzUdtnwovYMciM4ekx2aj1DDS5ZM7L2TonAf7Yu'
  'lZTspsObm/GNjgUwTeQp5ngKp0nm2MSfNW7MZ6s8SJRKtrRPRH0ipwayUaB3IB0q4a7GQ2R+'
  'mFVpqNDFRItDfaq2MWwfldtEFrRRHpDozpMqqe2XB9VVEVae6YMrSVZe6VigXUGYqU/3oLUS'
  'KhPNCimRuoB/c9Qoxa0RhDyZ8biyR7gjd038jAgsKqKI3cYQz40x+lz3VLxhTrTkdMLjewFY'
  '9JY4ctZssOOSJFGgd+SO1HgXyxdSHquVDPDs2CyYyS8elUf8aw3q5tNOd1qKG2hU6pmNkIMM'
  'Qj8smUuKvDKf82SqS+/BrF34plZ8LL75yO2Fl5bpaQQpeu/9FbnLrm1tIZaRs+6tiwS1pQ40'
  's1F5WdOoiKmoGu+RBdC0KmlsbDrb4eM64F4K1ILDv4sCW2yvGymxZj3EYTht8hrmlATYju8K'
  'dWZcqgBQg2gvWJkx8HgM6iX88gsgCJNgK23weaKkyeevHP8khoZAZlDVymipRTfIAu7BuZ4o'
  'HhW+To7rcfAuW8Awh7bEBToeaZeO5FnVd9UBGxC8mZB0KUJj/ewNhQg9wWbxun97rwfILLMd'
  'Dn5134uorm2s3xE4w8N/ALjRxbVZJZfBENuUuEw/SjDziO5ijVOzPOiNFX2xllvFjIrvnR5u'
  'Jq4o7kbsXrUlmq1qSim7zSopABwwiWMLvU1+MVE4Htu5qRmXxEdX6PMMoeUkaIZVr0w1XEKt'
  '0v7pKpXHGxtnN80AyXMj2mxoJHi7rJXf0cVuCe/WmziKKvoMFExBf9TBocfi4s7bOD8vQrLl'
  'gUtUlo6gXpztMRz+BiXUasX/BEp5cAdwsKWf4ITNCJzRKHuzyyxnXFUyNmHLsVjI4B0xbail'
  'PdHnsO5Buw7I9afNH3UNCuzOd1KCLukv+byv+pixgad2uXdClLxg3/W+NXaxDzLJHDhqm+3F'
  'VYIRjBN8ZAefiMqiZHpd7c98a9F4KNxASDOKwkQpIBwvKludhxGCiX3ooalflYk22yZNofkR'
  'hU6jW/HhunJwTbaxtXFJTeZULVn4BGqu8vKb/yCNl48KLiq0yM9OLCZmxaIxSOaTd7PZNj/Q'
  'mgTJjuBwn4zeyYU8x9YUPPB01hFdPMR1UEZr329ARONv91huBJX6DCTiB49iGtf2ZY7GWkHY'
  'sd8w+w71P+tfwTgRTaS4SA9aQ9bGY+MoAsnaGsXYqHqk2DSc08WJTCdzcJHPi+61yKw6rvzE'
  'idtJaQ3dOCWYHi5v5Tap6baDF6tG633H29zMfb2rx+HdcFlV4tOAckb+hpEyrOss15kjE5lw'
  'clSfH17baWcs38+1n4VVuRgyDsb20wZKliq1Z1XaFemr4z3RHtBmrtROZwrUBGPko7RWXGYx'
  'PiNoR6/Uz3msnQLPkjGyprnNZP9u1UXkinLV582CcoN4tLV1+9hj1k6+qWgv/S5WNoN1TZvj'
  'fw7aMvOPWZarOpo/K2Vo1feC9iO+bRw2keLd5wqWP4vYHCLP9EIpiQLYTsUrtNlr/CVD6n8z'
  'nk0fAGZ08bDg+7bNXA4p2T8+D6lVyOiEevNo6T7vi44hHx04489q4ShCP/XtTUKwEL6U9k8z'
  'XrECiPZSmYmFhteJFQ9RR7zq+awdBun7L2Gy0Fxvd3jNMjfjx3EGFv4egOnSYArYMGbiF+d0'
  'DHkbSzkdWmQKN2+M7nZaMbo+iDf0m5sBVKV6cmfG+XpLzvUe0VryqV9fAw6cibyx3XrE2k3H'
  'yDDzP6hoyRusaACWp0Tbq8kG+Yp/SnWxCasMS2Q00BBH7Mq6RdWtqCvaUtVJopmrRJtMeF0U'
  '7AyMiBDfS4XJ6rKFvbBOhd5cxNVQbjBjZqwlblJ3wiGN6X0fZHz35wA6geS1/Ir5pjlqTMW9'
  'OENsPyUb7QECs3zGeUAnpvm0xp1zL1QmcW6XKufFDzNJsGGmeG45fEZU86wW6hsBou2BdjkO'
  'HNIZGQuCkC4Ut82t3rgnj8cqNnxf9yXd9nRw/vHSKV3bNFpkdNGunOC8zxJrMiQiZxpJHHSw'
  '0qXqU/D5e4yVTx2Or8fNBRWRgatKXWlqDWDdToujYng87hlnLlOPmoADdQ7OxfMuXeotuwsz'
  'qupQVHoZ1tUxxibPYn6AlOJczMk1tM5bOwm9RIvNINPaY5IvX7nanDu1ffWecbyGRGi9mBRS'
  'q727VSiYQaaUa3wRlm5FgwiVYGk4dIE9kVkaj/TXRf23jyLpLIOhfy6qEcjvC+UzVQOIFLE0'
  'hpyW6lCWF0Be8CkbsDnMqYp4vv6TPDV9Id0o4KTzj7vN5MpXZkFDbTQ7By+j9DHOf5OLNrC5'
  'IJ80TjwYAN+anfAkiJzmz/Xi0dV56kU5CEJiDMvu/bTmoqvXBZBpdVzczc5ppBdkgacTLg14'
  'pSglyIamkoU18G7QhJWBq7xSO72kYVg7mDNn+uOUPh10z1Agl+AlvHdEzSg1vxAbixH3I2CI'
  'MEN5wxUkzReXCCwYAB7shbuVbGNbr9S7WcskXsRew3E6EeCJf0A4iyYd9rewScivwEeRK75A'
  'PJKN8bAw76uBpt75hox9lJ/eGSau6GOqlvq9epOo/qGzIOyglBTv6qZxDl6FDI0uWqlQ/egg'
  'hVgxeVKklV9hPCNc4VR8zAizByBtpuQziTu6L7YyfRS9s4+k9FrNEnDYB/o8VjjdCzmLlYuC'
  '+Z47hM+nBgdwFRZI2LT26RCmTMNYxGDsPAvF1LjsfybKyC7Zb1G1aR73Yle1/F16ie1Hj4vD'
  'ojJShrwWzsDxUqoAohVyCtLxVYQ58oyV2aA9ykMRNAHA0QiLbmXQThVO7FTNf4BXmPSbRAsJ'
  'zvFUZjxfqrtQh5kto4veoKWPaf9k8O+gEBnj0gZDDNFl0fYGnPNYooX6FcHPi8VnmMEBkuX2'
  'tWyqdJclwps+YCi+wckuak8XYrznj/EZxKD1JTdc2kcZzNj7eJdvuIAixthvCW6MjnotozAJ'
  '1lmqmGyUbAddJpVUydoCwYwZdnpD/SeH8IQLg3TIS8RFHxU4sKZxJSvihYyjSJGFMcVlc1Kw'
  'kG3sOFtHsZN16Gj8Ah0T2r1BEIlrmzjfwJQqZ4xDHfHdWCDBn2raZsNMWHa3wxp2wMA/ajjd'
  'kTePQVTZ45nsJyMJQXf/UBuYQttQtbXXJOWzskHl+f8mUvWxqTFsPeygNoCKUUtwubiURekq'
  'u0QhKWWyrUVrze9F7xyGMlCfSZuzdNB7e1b0QrEAO7aYxbwPFMHveL8FX+mOfN+++5cPH658'
  '9Lo6oJ1sLUryKKQ5AgY0fEZ4EYiNM1XO6o4qw04+YruUaxdZB7cyKJtflqLXuWBv3LyEOe8s'
  'Yo7AKlQBdjCp7Qm+qRPX2qwEp/Er8IePCuT0VGU2iDxUXbZM0RCgDy1UOJLDgC/5BtmChvUD'
  'Zw78p81ryxy+sPIkL+SfC4Pn/vry/IjGEH4tI7dZZKw38/IIrZH7b4YSz8eMrYEg+/q+vXhA'
  'o41zeyC7atUDkSx/8b3XFmZvOZlqsDny/YgDDe61ZWnf/paTJNwtKqO4B4zhWTwtJLvzAk53'
  'p5Hf7vePKJpUcixPm0tH8GPO5hHWrNCFcFWkPbb73WHKjKtGaDUsKYvCIuRSck6oEzRn3vFw'
  'l9PMvl0IYOXxzXrmMXWF7ju/A7r7mxuDeQCFj8euz+vIVHFEhWLpfEt6nNkZh02z9kYFGRsG'
  'L+tT43ocyg5ElieDLYJjR9XszLmIKNRb7IRYRKopfAijEdcM9tj1xFRitYSaxpTFlKAiUIpA'
  'jGoFuLZ9t4vKDUPxBx4v09nSyGEUF3yOSVnbewTXOsNoLimQX0rz/SbmEGw2vy7+TOOu4KVO'
  'mILmVwA9SexdYbhprYpqyMug4e8sZ+daeVGjlVJFHPW8dzb0iinkghvUGeVqIEYEmtSrSnHH'
  'vU7cZLZW+Vj6DrHBaVPcFwpzOHLvwOEOahz7WQ+zQVRpbCWhRqJB5VTtSd4znlTd5Vj3yjSz'
  'DJj6PzwLRwwp8wPEBTTlYTteB2IIl5TPinABTqMcfBfxcNHBRt0k+Mmp8i7ItY5EcHl0FJ3P'
  'kscpU47znCWle25tZ0C5oF1ifklcndGyCkb/G58NyEvj5aRqws7RRiXyDgQvjpM3SJWQEStA'
  'Y7P874l8S+88KvFm2aS8Ob9gZZGODGVsPEDOehtOgHBnvEU0ymZXeDi2k9O89WWaQv8+3lmJ'
  'h8pszABaCUwf+wOAhLptdpIwVuPYJ2wsXNTCRt+9ZgL29zWIvNNjX2qHNu7IT0BuOVMq61Gd'
  'B9aUJpRvguKEwJjdlPj7trPqNi0Zj98X1Xog0LFZANUcPXbIvovIB2Pt+hkOG7JRzHbZ3tM9'
  'fDpq8ajo52yRp6T7kHHMRWMf9/EbdpPmaJFBANjugpK0aa2EvWAcVG6vzKN8nbHlsO35xxoe'
  'yFSaZCUeonM7KvQU3k54eRJj/g+OnIAGAbQ3eIkomQrB4mEDuY3O/lHMDBr6fvDm7IKEcrLH'
  'R8ixEZy5qnoUyAWCzelz/xNUtYtUcB4O/4dhS0Ub3ZjCmU7DfhXZJ5vHIHxqJtwQI8Ufow5N'
  'WJWZa/Q7mYsbyT6WPPa4g5Qj7XNu0IZ2IOkCIIbDQvJ57KBLo5v+q42qJyDl9mG9vpXpD4pc'
  'G3Mgxk7xLvEYXpglAbVLnl+wJ4BbIHgRwLD1XkwyH3zEzW+nlT3Zah7brNnhtWP89Bi0hOZz'
  'ClXXOYXyRbsXJIGbkFRMvZFreSlhpQ3HdSphLSDF4pYJA3Jhb5ly5h73gJrH5Cnl3m0VkMLj'
  'DJByYmZkipMx6X/uXYa5dX1Gvr1oZcktb0E27e4A2QJRuTsrEpNoWA5re3hoWbH4MF/rsvpT'
  'kKnEtj036y+Oof1Gf4WcEX0XrdYu4HPSTYq8qH6ZsGkrOL7QvKeR/VbPiu1jmLFFaIz0K8fb'
  '3Nx9vcFD7e5sKBTXCm0K5A/txwpcmO4jvvu1Bj1zOZENQyZ+mnuEXLuy8meO3m6rUaFHaJ4M'
  '1XiSU4QatQ2EPi0xynRjOzT1bLZ8qKuvsLjM/zj9q06srPPcCVp6YOPBTdgAeZkaq/TPYCsG'
  'hEZb7KCQrAtZTJ8lFYHjn9nCLfFVRDhCoqvo5bits/OZArNVzkvxTOVCyUK+eMosMdBfBCun'
  'xj6vyjfSdcfiRipxFwi0fSen/0unZtJ7KCEcarSl0G2Mk3bt5xtiXqjI0S7pFxCKNpNCWiWE'
  '3r+Mify8JDrOW6oeWtHllkrb65rbXGkgLt1JFn7OK19rrbGKR3tmQQJzQcMLz8RqSGP1vMxR'
  'FLVtoT1wPbHzOxsamyGQl9bdo/nkByP+8DLtng3sSbD2y4E6j1JdUGgrfmWyjYIylBWRivLX'
  'gbt26QTIzdZfcmNexnp0+qm8re6NCzNrlmBw4mrcHufXMd234t3Rwl383I92OAIaH6EgEugP'
  '2CvuMvWfOAoAzwiNETuZXA6jJIWVOBomUiGGtE5ex5Bv9Zrrid8pWlaCGc3aOoQykzrb30ed'
  'F68h0Z6z0/zF2Yh1prwG0sVdp4ndNynyCFKfiae6SPdwxD9HdnsJXIwc85ncs+73HFKdhds/'
  'u+kLAa+4oKNrKD5c027Yv2yTdJ/yIiVSIXENeIWsT9UYNipzS583x8rJei8TiTq3br+7ycFc'
  'sLA8vI3f4hSoM3z7HxP26Fd4vV44obyLSKou7dfMmeKvNfU8OIuKqHjzNywyurFYYqahm2mx'
  'ieiv53VqXDs2JEBQCCeOAV8H6GL9ezix5P8HFw2Wdx/Q6LxE5mbowqfCLZynzNskxqtCZ4w/'
  'G/3M0XvyjI8XcjwMa86PrzkjHJSz8UE12vHAsLGrD1FMnYwN7HAaW/cLY7BTBXV/yWEh0siw'
  '9yet7FMJOt+ASLIXYpG+urvemeUzQluUts2MByuTAEjN1A7tC7V+HRpiqcMzUDrdzjjmQuFO'
  '0gYuNXjMwGQS5Y8tcOLiJp7dxW7pn8xpaG020ierUEnbLgOoo43ApFosuZlAd3NZfEwG0tbm'
  'XR7AwJwWI7au1Hua5+wpKWd2cggCIRlPN1qwV3s2idXTZ9MbA32ixhPWy5G0wqvXrOLQ7kGn'
  '9T2pe1aiZTXdhIsRgFZAJB6ZMlJhxARjtY92+ST3lVLVAcOFjux45QPKgzyFCfp6ktGyG1YP'
  'ZAb6Oma0p6itMnjAMd9ggtlTSvw+2guryaYvJJvZjCq4VenwAcjf6Xv9r/xBqzYjUOhBZibi'
  'APWQoG3xlB3r8A+4aclm6ghln/JXAtcuBY9s7pwMoHPvnDyHgwNnOKer6OPkU+qUFqCWo1dp'
  'QaX1RvFFOO5ep2o5r4ZCUwGumAuz0jbwJDSZKED1CS3bVQtT4QQ51YaAMZGBilVjXJS8CFQ4'
  'wqZCe1p8Ve5Ai9Yf02bhPc1H/I571r4VWp/xtfp05Nj4Xyc/ts4EttEgCkvaoWHX7iuBCuUW'
  'Zn2SnTcHs2tZ4kmzpAZI0tLTrZ+G5SWWyp4C5yr84O7DPmXYTlQe8CTIN8YQQ/hyL1DLhZXX'
  '2JrZG4mFgq41Vpvtu9UuaP2CKwHphRFVcK765maCG79+pF3oGXE+G6/Pef9E2IAaXIf8vZ+s'
  'Ax3/LCvxNnoR1Hq5fPHdjSgiVX2YDE2VBOQfgBvhw1mpprEkP++2pxQO3F1hY8zCaaK7XHc7'
  'lWuwUNPgfzznYGs2yxPwEoY70JJJ4azNOh3VATE2zaPQ9f8E3lt45QHGioYl0FKbTDP28Jnp'
  'wKZkr54xhjySTlZXYPpDDW1otW/JSjH287jf846/l6GFARMeLzvcGwQoFNeQyv7d5YpByo6j'
  'kILRFJrClgQnwy/rhePg1FkpFdalzW7XL93eRO7T9PrPUK5zhCMiE4Zzw/sgnV56gC8jZoRP'
  'cCayBplvGcLG9MciPxrFWW5MaFthzgZ/rYbtvxw6GLznHBEam15YeyJO7PSMyMZLZ4xcFu5V'
  'w1Wqwe5JAVql8yLe7wDHb1i49fH+T0/ruXOowLpJIbf7zR94CywU7v8AsPWp0Nzgx8ynHt0j'
  'tyP1jD9sJPpukYRUrDZKVl4TapG/dct8TtdBs5bHqT1Fgliha7a/CcTqVCh9ZPV7KcJ3Iwxg'
  'Sv46ib0l+ilxdxblqTZAHBnqkguWM+0RPSg+b+h6PcZF8nhOeIIaPpXVLFmA/OL58l/rumma'
  'LNzpqF9yEzgDeUBIZJOkQ0VkF6k5U+WNqZKq71tkIoBfN1NBgBhCgxY3KV/CvJqPc3cRb6t4'
  'i+h85wwfQ/y3Jym31u6uDXRNq7eoSF0sA59YTwzZrgZDECpZaDwT4LtgBSvVJFLIMNJoxjMR'
  'GgH+WgHpGD4QyAcSOevYr2EMiFqFCLD6DEYkpT7mgVDrdoO8UKPWZUVvIF9RXFk1N2UGt297'
  'gQOqGn4SOfPpd+4dbVZ/JPWLUaP4eBPP5a2odPS7px5poPvjM4NdNyUakxzjca/8b6NRnatP'
  'xbQe3BaoenptmWdjDQ0Obs7VVaSf0cJLHGvVmQDcfe4VUtTENLlkp1ZAxaS3j/P3RKcX0wa5'
  'X5x6OvujjpKSVPZGNsG+rFE2XO487PlMPfn2pC2DaI7QKoP3lcFr3LU1UwVCKpOV8u6C9XUD'
  '1QAyOhIU423ahzbVDIhZCAvBgVMCmk9ed8OqkLPI/jt4OeCyrF5tQoK+bG0bl95asJ4ZPwyy'
  'f/xlGiZTO7A7Ok1m3d7mzHKFDV3CbeCHpUcf6juCdKP7vAYOCBbziHwUYkCykDXFhVH7jPRU'
  'AdkpDHRIw46aNEZMhbPgVoMPlOCemLSGLk3y7RvNbVF+Pao5WBn90V+rYLLQg+HEf6kxXIl1'
  'kMac9Jtb0p6YIwvOkK+ueaYDK4yQ+ZTeqDy/WpvqgLV183KMQbz9hgi7yejFr3/ua4wFZ7+k'
  '0gDg1VUnMNNEjbrdGNSwb2L3n0IM+5ObocPZfbU6N6wjHb+lEJF6BlQzMB0ZZz1NpUlYJcxK'
  'oO1aF61O4h+kSiKXlHC5e97+0ZHQNYuvkRloiILuWv7mmkGpPvUfEDRl7PTuVdjjETvroP9s'
  'IKWeqr5anLvRZG4rRGC+O7RQk5j/HaOJKFFkLR9qT6acHq8jYLCCwg71yqutbJtb59zSWy3S'
  '7y6j+rzj1mu6mYjvlx215MSdUjFTZH/Fj69bm4ly5wwZGjtfebP9fgOmTV7MqRinXKPq2VDV'
  'N6FuOYwp6+GqlKEBZjPxjYY2sNqJ0RgEEo/GPLweU59BefRkNSKC5HsBePu4EZremE8dXo0w'
  '6RlA0gcLNl0xx5a7UQUMOfQHhFS8oJEbkXNRE9nIFdDsFYO6reJAOK5vHz7GmrOM91ujKil5'
  'raAhAQb2/3Kfp2U81WVVh6WCrcOWMaaxQlovxvs4WvzSW1zsjzHUHLexIOAfYg2Ua9/FBre8'
  'x4PV4a+IALrlV3LPBZLK6U2MxHmDXhs840e/g+zbUl/iiEYPUA38fmSsS/mNv8VbO1lvJPnu'
  '2OTnH8DqwjDRLTUUtosiOoS3HVaX7ibbZej78TXOIzM17fzKeo2o2e5FwjqKsGMiw0zf19xI'
  'FV1sE1dlzrpnUjQ98R5VSrpxgjX1S6WaBEoXSCpkmKetl6RpwmEIhGEKXQhP0l+/P+F7ui//'
  '2Q==',
);

/// JPXDecode runs inside the web worker (web-default conditional
/// imports), so every assertion below exercises the worker's parse
/// path end to end.
void main() {
  test('browser worker decodes a gray JPXDecode image to the VM-identical PNG',
      () {
    final book = Unseal.parse(
      jpxImagePageFixture(grayJ2k, width: 64, height: 64).build(),
    ) as PdfBook;
    expect(book.files.images, hasLength(1));
    final image = book.files.images.single;
    expect(image.path, 'images/pdf-image-8.png');
    // The dart2js build must produce the exact pixels the VM produces:
    // the 5/3 lifting normalizes every arithmetic shift with
    // toSigned(32) because JS shifts come back uint32-normalized. The
    // PNG byte layout itself may differ (the archive deflate is not
    // host-stable), so the golden pins the inflated IDAT rows.
    final idatLength = ByteData.sublistView(image.content).getUint32(33);
    final rows = Uint8List.fromList(
      const ZLibDecoder()
          .decodeBytes(image.content.sublist(41, 41 + idatLength)),
    );
    expect(
      sha256.convert(rows).toString(),
      '28cf14e6c0b00d9f9c171d95af232ae5fddc0208904cc5bbbca5eed70dc08eaf',
    );
  });

  test('browser worker decodes an RGB RCT codestream', () {
    final book = Unseal.parse(
      jpxImagePageFixture(rgbJ2k, width: 64, height: 64, components: 3)
          .build(),
    ) as PdfBook;
    final image = book.files.images.single;
    // Color type 2 (truecolor) at IHDR offset 9.
    expect(image.content[25], 2);
  });

  test('an ASCII85 chain decodes to the same PNG as the direct stream',
      () {
    final direct = Unseal.parse(
      jpxImagePageFixture(grayJ2k, width: 64, height: 64).build(),
    ) as PdfBook;
    final chained = Unseal.parse(
      jpxImagePageFixture(
        grayJ2k,
        width: 64,
        height: 64,
        ascii85: true,
      ).build(),
    ) as PdfBook;
    expect(
      chained.files.images.single.content,
      direct.files.images.single.content,
    );
  });

  test('JPX images survive the book wire roundtrip', () {
    final book = Unseal.parse(
      jpxImagePageFixture(grayJ2k, width: 64, height: 64).build(),
    ) as PdfBook;
    final (json, blobs) = encodeBookWire(book);
    final decoded = decodeBookWire(json, blobs) as PdfBook;
    expect(decoded.files.images, hasLength(1));
    expect(
      decoded.files.images.single.content,
      book.files.images.single.content,
    );
  });

  test('a corrupted codestream degrades to geometry-only, never crashes',
      () {
    final corrupted = Uint8List.fromList(grayJ2k);
    for (var i = 40; i < 64; i++) {
      corrupted[i] = 0xFF;
    }
    final book = Unseal.parse(
      jpxImagePageFixture(corrupted, width: 64, height: 64).build(),
    ) as PdfBook;
    expect(book.files.images, isEmpty);
  });
}
