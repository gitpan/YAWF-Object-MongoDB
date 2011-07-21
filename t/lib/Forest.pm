package t::lib::Forest;

use strict;
use warnings;

use YAWF::Object::MongoDB (
    collection => 'Y_O_M_Test_Forest',
    keys       => [
        {
            birch => 1,
            oak   => 1,
            color => 1,
        },
        [ 'deer', 'boar','color' ],
    ]
);

our @ISA = ('YAWF::Object::MongoDB');

1;
