local extra_table = require "./extra-table"

local arr = {}

print("START", extra_table.getAllocatedArraySize(arr))

arr[1] = 10
arr[2] = 20
arr[3] = 30
arr[4] = 40

print("END", extra_table.getAllocatedArraySize(arr))
