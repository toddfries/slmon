package SLMON::Dish;

use strict;
use warnings;

use XSLoader;

# Loaded only inside the dish child, after fork. Pulls in libgrpc++.
XSLoader::load('SLMON::Dish');

1;
