module BATL_size

  implicit none

  SAVE

  ! Dimensionality of grid and AMR
  integer, parameter :: MaxDim = 3    ! This has to be 3 all the time
  integer, parameter :: nDimTree = 3  ! This can be 1, 2 or 3

  ! Maximum number of blocks per processor
  integer :: MaxBlock = 0

  ! Number of cells per block in each direction
  integer, parameter :: nI = 8, nJ = 8, nK = 1

  ! Array for block size
  integer, parameter:: &
       nIJK_D(MaxDim) = (/ nI, nJ, nK /)

  ! number of ghost cells
  integer, parameter :: nG = 2  
  
  integer, parameter :: &
       MinI = 1 - nG, MaxI = nI + nG, &
       MinJ = 1 - nG, MaxJ = nJ + nG, &
       MinK = 1 - nG, MaxK = nK + nG

end module BATL_size

