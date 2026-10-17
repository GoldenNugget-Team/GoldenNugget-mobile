/*
 * backup_test.c
 * source libplist regression test
 *
 * Copyright (c) 2009 Jonathan Beck All Rights Reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301 USA
 */

#include "../plist.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
  if (argc != 3) {
    fprintf(stderr, "Usage: %s <file1.plist> <file2.plist>\n", argv[0]);
    return 2;
  }

  plist_t a = NULL, b = NULL;
  plist_err_t err1 = plist_read_from_file(argv[1], &a, NULL);
  plist_err_t err2 = plist_read_from_file(argv[2], &b, NULL);

  if (err1 != PLIST_ERR_SUCCESS || err2 != PLIST_ERR_SUCCESS || !a || !b) {
    fprintf(stderr, "Failed to read one or both plist files\n");
    return 2;
  }

  int equal = plist_compare_node_value(a, b);

  plist_free(a);
  plist_free(b);

  return equal ? 0 : 1;
}
