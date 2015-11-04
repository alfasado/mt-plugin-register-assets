package RegisterAssets::L10N::ja;
use strict;
use base 'RegisterAssets::L10N';

use vars qw( %Lexicon );

our %Lexicon = (
    'Upload Common assets and index templates from ZIP file.' => 'ZIPファイルをアップロードしてアイテムとインデックステンプレートを登録します。',
    'Register Assets' => '共通アイテム登録',
    'Are you sure you want to register common assets?' => '共通アイテムを登録しても宜しいですか?',
    '[_1] templates' => '[_1]件のテンプレート',
    '[_1] assets' => '[_1]件のアイテム',
    ' and ' => ' と ',
    'are registered.' => 'が登録されました。',
    'File uploaded and RegisterAssets worker added to queue.' => 'ファイルのアップロードに成功しました。共通アイテム登録キューが予約されました。',
    );

1;